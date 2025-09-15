local time = require("time")
local uuid = require("uuid")
local logger = require("logger")
local consts = require("consts")

local function run(config)
    config = config or {}
    local log = logger:named("kb9.service.root")

    -- Enable link trapping for controlled failure handling
    local ok, err = process.set_options({ trap_links = true })
    if not ok then
        log:warn("Failed to set trap_links option", { error = err })
    end

    -- Initialize state with pre-allocated tables
    local state = {
        shutting_down = false,
        operations_count = 0,
        start_time = time.now(),
        kb_processes = table.create(0, 10),      -- component_id -> process_info
        message_queues = table.create(0, 10),    -- component_id -> command_queue
        startup_timers = table.create(0, 10),    -- component_id -> timer
        idle_timers = table.create(0, 10),       -- component_id -> timer
        pending_work = table.create(0, 10)       -- component_id -> work_count
    }

    -- Register service in process registry
    local ok, err = process.registry.register(consts.PROCESS_NAMES.ROOT_SERVICE)
    if not ok then
        log:debug("Registration failed", { error = err })
        return { error = err }
    end

    log:info("KB9 root service starting")

    -- Setup communication channels - simplified to single command path
    local events = process.events()
    local kb_commands = process.listen(consts.MESSAGE_TOPICS.KB_COMMAND)
    local kb_asks = process.listen(consts.MESSAGE_TOPICS.KB_ASK)
    local ready_messages = process.listen(consts.MESSAGE_TOPICS.KB_READY)
    local timeout_check_timer = time.ticker(consts.KB_PROCESS.TIMEOUT_CHECK_INTERVAL)

    -- Helper: Get KB process registry name
    local function get_kb_process_name(component_id)
        return consts.PROCESS_NAMES.KB_PROCESS_PREFIX .. component_id
    end

    -- Helper: Send startup error to queued commands
    local function send_startup_error(command_wrappers, error_message)
        local wrapper_count = #command_wrappers
        log:info("Sending startup errors to queued commands", {
            count = wrapper_count,
            error = error_message
        })

        for i = 1, wrapper_count do
            local command_wrapper = command_wrappers[i]
            if command_wrapper.reply_to then
                local startup_error = {
                    startup_error = true,
                    error = error_message,
                    component_id = command_wrapper.component_id
                }
                process.send(command_wrapper.reply_to, consts.MESSAGE_TOPICS.KB_ASK, startup_error)
            end
        end
    end

    -- Helper: Reset component state on failure
    local function reset_component_state(component_id, error_message)
        log:info("Resetting component state", {
            component_id = component_id,
            error = error_message
        })

        -- Send errors to queued commands
        local queued_commands = state.message_queues[component_id] or table.create(5, 0)
        local queue_size = #queued_commands
        if queue_size > 0 then
            send_startup_error(queued_commands, error_message)
        end

        -- Clear all state for this component INCLUDING pending work
        state.kb_processes[component_id] = nil
        state.message_queues[component_id] = nil
        state.startup_timers[component_id] = nil
        state.idle_timers[component_id] = nil
        state.pending_work[component_id] = nil

        log:info("Component state reset complete", {
            component_id = component_id,
            notified_senders = queue_size
        })
    end

    -- Helper: Start new KB process
    local function start_kb_process(component_id)
        log:info("Starting KB process", { component_id = component_id })

        -- Spawn monitored process
        local pid, spawn_err = process.spawn_monitored(
            consts.PROCESS_SPAWN.KB_PROCESS_ID,
            consts.PROCESS_SPAWN.KB_HOST_ID,
            component_id
        )

        if not pid then
            log:error("Failed to spawn KB process", {
                component_id = component_id,
                error = spawn_err or "unknown error"
            })
            reset_component_state(component_id, "Failed to spawn KB process: " .. (spawn_err or "unknown error"))
            return false
        end

        -- Link to process for failure detection
        local link_ok, link_err = process.link(pid)
        if not link_ok then
            log:warn("Failed to link to KB process", {
                component_id = component_id,
                pid = pid,
                error = link_err
            })
        end

        -- Register in process registry
        local kb_process_name = get_kb_process_name(component_id)
        local reg_ok, reg_err = process.registry.register(kb_process_name, pid)
        if not reg_ok then
            log:warn("Failed to register KB process", {
                component_id = component_id,
                error = reg_err
            })
        end

        -- Store process info
        state.kb_processes[component_id] = {
            pid = pid,
            status = "starting",
            stats = {
                commands_processed = 0,
                start_time = time.now(),
                last_activity = time.now()
            }
        }

        -- Set startup timeout
        state.startup_timers[component_id] = time.after(consts.KB_PROCESS.STARTUP_TIMEOUT)

        return true
    end

    -- Helper: Track work completion and manage idle timer
    local function on_work_completed(component_id)
        local pending_count = state.pending_work[component_id] or 0
        if pending_count > 0 then
            state.pending_work[component_id] = pending_count - 1
            log:debug("Work completed", {
                component_id = component_id,
                remaining_work = state.pending_work[component_id]
            })
        end

        -- Start idle timer if no more pending work
        if state.pending_work[component_id] == 0 then
            log:debug("All work completed, starting idle timer", {
                component_id = component_id
            })
            -- Start idle timer
            if not state.idle_timers[component_id] then
                state.idle_timers[component_id] = time.after(consts.KB_PROCESS.IDLE_TIMEOUT)
                log:debug("Started idle timer", {
                    component_id = component_id,
                    timeout = consts.KB_PROCESS.IDLE_TIMEOUT
                })
            end
        end

        -- Update last activity
        local kb_process = state.kb_processes[component_id]
        if kb_process then
            kb_process.stats.last_activity = time.now()
        end
    end

    -- Helper: Track new work and cancel idle timer
    local function on_work_started(component_id, work_count)
        work_count = work_count or 1

        -- Cancel idle timer since work is starting
        if state.idle_timers[component_id] then
            state.idle_timers[component_id] = nil
            log:debug("Cancelled idle timer - work starting", {
                component_id = component_id
            })
        end

        -- Increment pending work counter
        local pending_count = state.pending_work[component_id] or 0
        state.pending_work[component_id] = pending_count + work_count

        log:debug("Work started", {
            component_id = component_id,
            work_added = work_count,
            total_pending = state.pending_work[component_id]
        })

        -- Update last activity
        local kb_process = state.kb_processes[component_id]
        if kb_process then
            kb_process.stats.last_activity = time.now()
        end
    end

    -- Helper: Flush queued commands to running process
    local function flush_queued_commands(component_id)
        local queue = state.message_queues[component_id]
        local kb_process = state.kb_processes[component_id]

        if not queue or #queue == 0 or not kb_process or kb_process.status ~= "running" then
            return
        end

        log:info("Flushing queued commands", {
            component_id = component_id,
            command_count = #queue
        })

        -- Track work for all queued commands
        on_work_started(component_id, #queue)

        -- Send commands array to KB process
        local commands_wrapper = {
            commands = queue,
            reply_to = process.pid()
        }
        process.send(kb_process.pid, consts.MESSAGE_TOPICS.COMMAND, commands_wrapper)

        -- Clear queue
        state.message_queues[component_id] = table.create(5, 0)
    end

    -- Helper: Start idle timer ONLY when no pending work
    local function start_idle_timer(component_id)
        if state.idle_timers[component_id] then
            return -- Already has timer
        end

        -- ONLY start idle timer if no pending work
        local pending_count = state.pending_work[component_id] or 0
        if pending_count > 0 then
            log:debug("Not starting idle timer - work pending", {
                component_id = component_id,
                pending_work = pending_count
            })
            return
        end

        state.idle_timers[component_id] = time.after(consts.KB_PROCESS.IDLE_TIMEOUT)
        log:debug("Started idle timer", {
            component_id = component_id,
            timeout = consts.KB_PROCESS.IDLE_TIMEOUT,
            pending_work = pending_count
        })
    end

    -- Helper: Stop idle KB process
    local function stop_idle_kb_process(component_id)
        log:info("Stopping idle KB process", { component_id = component_id })

        local kb_process = state.kb_processes[component_id]
        if kb_process and kb_process.status == "running" then
            process.cancel(kb_process.pid, consts.KB_PROCESS.CANCEL_TIMEOUT)
            state.idle_timers[component_id] = nil
            log:info("Idle KB process cleanup initiated", { component_id = component_id })
        else
            -- Clean up timer anyway
            state.idle_timers[component_id] = nil
        end
    end

    -- Helper: Check for idle timeouts
    local function check_idle_timeouts()
        local idle_count = 0
        local stopped_count = 0

        for component_id, timer in pairs(state.idle_timers) do
            idle_count = idle_count + 1

            local timeout_result = channel.select({
                timer:case_receive(),
                default = true
            })

            if not timeout_result.default then
                -- Check if there's still pending work before stopping
                local pending_count = state.pending_work[component_id] or 0
                if pending_count > 0 then
                    log:debug("Idle timeout reached but work pending, restarting timer", {
                        component_id = component_id,
                        pending_work = pending_count
                    })
                    -- Restart the timer
                    state.idle_timers[component_id] = time.after(consts.KB_PROCESS.IDLE_TIMEOUT)
                else
                    log:info("KB process idle timeout reached", {
                        component_id = component_id,
                        timeout = consts.KB_PROCESS.IDLE_TIMEOUT
                    })
                    stop_idle_kb_process(component_id)
                    stopped_count = stopped_count + 1
                end
            end
        end

        if idle_count > 0 then
            log:debug("Idle timeout check completed", {
                checked = idle_count,
                stopped = stopped_count
            })
        end
    end

    -- Helper: Check for startup timeouts
    local function check_startup_timeouts()
        local startup_count = 0
        local timed_out_count = 0

        for component_id, timer in pairs(state.startup_timers) do
            startup_count = startup_count + 1

            local timeout_result = channel.select({
                timer:case_receive(),
                default = true
            })

            if not timeout_result.default then
                log:warn("KB process startup timeout", {
                    component_id = component_id,
                    timeout = consts.KB_PROCESS.STARTUP_TIMEOUT
                })
                reset_component_state(component_id, "KB process startup timeout")
                timed_out_count = timed_out_count + 1
            end
        end

        if startup_count > 0 then
            log:debug("Startup timeout check completed", {
                checked = startup_count,
                timed_out = timed_out_count
            })
        end
    end

    -- Handler: KB command from client - simplified to always expect commands array
    local function handle_kb_command(command_msg)
        local component_id = command_msg.component_id
        local commands = command_msg.commands
        local reply_to = command_msg.reply_to

        if not component_id or not commands or type(commands) ~= "table" or #commands == 0 then
            log:warn("Invalid KB command format", { command_msg = command_msg })
            if reply_to then
                process.send(reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                    startup_error = true,
                    error = "Invalid command format - commands array required",
                    component_id = component_id
                })
            end
            return
        end

        log:debug("Received KB commands", {
            component_id = component_id,
            commands_count = #commands
        })

        -- Initialize message queue if needed
        if not state.message_queues[component_id] then
            state.message_queues[component_id] = table.create(5, 0)
        end
        if not state.pending_work[component_id] then
            state.pending_work[component_id] = 0
        end

        -- Add all commands to queue with reply info
        for _, command in ipairs(commands) do
            local command_wrapper = {
                command = command,
                reply_to = reply_to,
                component_id = component_id
            }
            table.insert(state.message_queues[component_id], command_wrapper)
        end

        -- Get current process state
        local kb_process = state.kb_processes[component_id]

        if not kb_process or kb_process.status == "failed" then
            -- Start new process
            log:info("KB process not running, starting", { component_id = component_id })
            start_kb_process(component_id)

        elseif kb_process.status == "starting" then
            -- Commands already queued, will be flushed when ready
            log:debug("KB process starting, commands queued", {
                component_id = component_id,
                queued_commands = #state.message_queues[component_id]
            })

        elseif kb_process.status == "running" then
            -- Send commands directly
            log:debug("Forwarding commands to KB process", {
                component_id = component_id,
                commands_count = #commands
            })

            -- Track work BEFORE sending commands
            on_work_started(component_id, #commands)

            -- Send commands array
            local commands_wrapper = {
                commands = state.message_queues[component_id],
                reply_to = process.pid()
            }
            process.send(kb_process.pid, consts.MESSAGE_TOPICS.COMMAND, commands_wrapper)

            -- Clear queue and update stats
            state.message_queues[component_id] = table.create(5, 0)
            kb_process.stats.commands_processed = kb_process.stats.commands_processed + #commands
        end

        state.operations_count = state.operations_count + #commands
    end

    -- Handler: KB process ready signal
    local function handle_kb_process_ready(ready_msg)
        local pid = ready_msg.pid

        -- Find which component this PID belongs to
        for component_id, kb_process in pairs(state.kb_processes) do
            if kb_process.pid == pid and kb_process.status == "starting" then
                log:info("KB process ready", { component_id = component_id })

                kb_process.status = "running"
                state.startup_timers[component_id] = nil

                -- Start idle timer and flush queued commands
                start_idle_timer(component_id)
                flush_queued_commands(component_id)
                return
            end
        end
    end

    -- Handler: KB process acknowledgment
    local function handle_kb_ask(ack_msg)
        -- Extract component_id from the ack response payload
        local component_id = ack_msg.component_id

        if component_id then
            -- Track work completion
            on_work_completed(component_id)
        end

        log:debug("Received command acknowledgment", {
            component_id = component_id,
            success = ack_msg.success,
            ops_executed = ack_msg.ops_executed
        })
    end

    -- Handler: Restart KB process
    local function restart_kb_process(component_id, reason)
        log:info("Restarting KB process", {
            component_id = component_id,
            reason = reason
        })

        -- Clean up old process info
        state.kb_processes[component_id] = nil
        state.startup_timers[component_id] = nil
        state.idle_timers[component_id] = nil
        state.pending_work[component_id] = nil

        -- Wait before restart
        local restart_timer = time.after(consts.KB_PROCESS.RESTART_DELAY)
        channel.select({ restart_timer:case_receive() })

        -- Start new process
        start_kb_process(component_id)
    end

    -- Helper: Table size counting
    local function table_size(t)
        local count = 0
        for _ in pairs(t) do
            count = count + 1
        end
        return count
    end

    -- Main event loop
    while not state.shutting_down do
        local result = channel.select({
            events:case_receive(),
            kb_commands:case_receive(),
            kb_asks:case_receive(),
            ready_messages:case_receive(),
            timeout_check_timer:channel():case_receive()
        })

        if result.channel == events then
            local event = result.value

            if event.kind == process.event.CANCEL then
                log:debug("Shutdown initiated")
                state.shutting_down = true

            elseif event.kind == process.event.EXIT then
                -- KB process exited
                local exited_pid = event.from
                local exit_reason = event.result and event.result.error or "normal"

                for component_id, kb_process in pairs(state.kb_processes) do
                    if kb_process.pid == exited_pid then
                        if event.result and event.result.error then
                            log:warn("KB process failed", {
                                component_id = component_id,
                                error = exit_reason
                            })
                            restart_kb_process(component_id, "process_failed")
                        else
                            log:info("KB process exited cleanly", { component_id = component_id })
                            -- Clean up
                            state.kb_processes[component_id] = nil
                            state.startup_timers[component_id] = nil
                            state.idle_timers[component_id] = nil
                            state.pending_work[component_id] = nil
                        end
                        break
                    end
                end

            elseif event.kind == process.event.LINK_DOWN then
                -- KB process link failed
                local down_pid = event.from

                for component_id, kb_process in pairs(state.kb_processes) do
                    if kb_process.pid == down_pid then
                        log:warn("KB process link down", { component_id = component_id })
                        restart_kb_process(component_id, "link_down")
                        break
                    end
                end
            end

        elseif result.channel == kb_commands then
            handle_kb_command(result.value)

        elseif result.channel == kb_asks then
            handle_kb_ask(result.value)

        elseif result.channel == ready_messages then
            handle_kb_process_ready(result.value)

        elseif result.channel == timeout_check_timer:channel() then
            check_startup_timeouts()
            check_idle_timeouts()
        end
    end

    -- Cleanup on shutdown
    timeout_check_timer:stop()

    local uptime = time.now():sub(state.start_time)
    log:info("KB9 root service shutdown complete", {
        total_operations = state.operations_count,
        uptime_seconds = uptime:seconds(),
        active_kb_processes = table_size(state.kb_processes)
    })

    return {
        status = "shutdown_complete",
        stats = {
            operations_processed = state.operations_count,
            uptime_ms = uptime:milliseconds(),
            kb_processes_managed = table_size(state.kb_processes)
        }
    }
end

return { run = run }