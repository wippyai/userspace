local time = require("time")
local uuid = require("uuid")
local logger = require("logger")

local CONST = {
    REGISTRY_NAME = "scheduler.root",
    HOST = "app:processes",
    WORKER_COUNT = 5,
    WORKER_POLL_INTERVAL = "2s",
    WORKER_BATCH_SIZE = 10,
    WORKER_MAX_CONCURRENT = 20,
    WORKER_STARTUP_DELAY = "1s",
    RESTART_DELAY = "5s",
    CLEANUP_INTERVAL = "1200s",
    SHUTDOWN_TIMEOUT = "10s",
    WORKERS = {
        STANDARD = "userspace.scheduler.service:worker",
        CLEANUP = "userspace.scheduler.service:cleanup_worker"
    }
}

local log = logger:named("scheduler.root")

local function run(config)
    config = config or {}
    local worker_count = config.worker_count or CONST.WORKER_COUNT
    local worker_poll_interval = config.worker_poll_interval or CONST.WORKER_POLL_INTERVAL
    local worker_batch_size = config.worker_batch_size or CONST.WORKER_BATCH_SIZE
    local worker_max_concurrent = config.worker_max_concurrent or CONST.WORKER_MAX_CONCURRENT
    local worker_startup_delay = config.worker_startup_delay or CONST.WORKER_STARTUP_DELAY
    local cleanup_interval = config.cleanup_interval or CONST.CLEANUP_INTERVAL

    local state = {
        standard_workers = {},
        cleanup_workers = {},
        shutting_down = false,
        shutdown_tracking = {
            standard = {},
            cleanup = {}
        }
    }

    local ok, err = process.registry.register(CONST.REGISTRY_NAME)
    if not ok then
        log:debug("Registration failed", { error = err })
        return { error = err }
    end

    local success, error = process.set_options({ trap_links = true })
    if not success then
        log:debug("Failed to set trap_links", { error = error })
        return { error = error }
    end

    local function spawn_standard_worker()
        local worker_config = {
            batch_size = worker_batch_size,
            max_concurrent = worker_max_concurrent,
            poll_interval = worker_poll_interval
        }

        local pid, spawn_err = process.spawn_monitored(
            CONST.WORKERS.STANDARD,
            CONST.HOST,
            worker_config
        )

        if not pid then
            log:debug("Failed to spawn standard worker", { error = spawn_err })
            return nil, spawn_err
        end

        local link_ok, link_err = process.link(pid)
        if not link_ok then
            log:debug("Failed to link to worker, continuing anyway", {
                pid = pid,
                error = link_err
            })
        end

        state.standard_workers[pid] = {
            started_at = time.now():utc(),
            config = worker_config,
            linked = link_ok
        }

        log:debug("Standard worker spawned", {
            pid = pid,
            linked = link_ok,
            monitored = true,
            config = worker_config
        })

        return pid, nil
    end

    local function spawn_cleanup_worker()
        if state.shutting_down then
            return nil, "Shutting down"
        end

        local pid, spawn_err = process.spawn_monitored(CONST.WORKERS.CLEANUP, CONST.HOST)
        if spawn_err then
            log:debug("Failed to spawn cleanup worker", { error = spawn_err })
            return nil, spawn_err
        end

        local link_ok, link_err = process.link(pid)
        if not link_ok then
            log:debug("Failed to link to cleanup worker, continuing anyway", {
                pid = pid,
                error = link_err
            })
        end

        state.cleanup_workers[pid] = {
            started_at = time.now():utc(),
            linked = link_ok
        }

        log:debug("Cleanup worker spawned", {
            pid = pid,
            linked = link_ok,
            monitored = true
        })
        return pid, nil
    end

    local function restart_standard_worker_async(dead_pid)
        coroutine.spawn(function()
            if state.shutting_down then
                return
            end

            log:debug("Scheduling worker restart", {
                dead_pid = dead_pid,
                delay = CONST.RESTART_DELAY
            })

            time.sleep(CONST.RESTART_DELAY)

            if not state.shutting_down then
                local new_pid, spawn_err = spawn_standard_worker()
                if new_pid then
                    log:debug("Worker restarted successfully", {
                        old_pid = dead_pid,
                        new_pid = new_pid
                    })
                else
                    log:debug("Failed to restart worker", {
                        old_pid = dead_pid,
                        error = spawn_err
                    })
                end
            end
        end)
    end

    local function handle_worker_exit(pid, result)
        local standard_worker = state.standard_workers[pid]
        local cleanup_worker = state.cleanup_workers[pid]

        if standard_worker then
            local was_shutdown = state.shutdown_tracking.standard[pid] ~= nil

            if was_shutdown then
                state.shutdown_tracking.standard[pid] = nil
                log:debug("Standard worker shutdown complete", {
                    pid = pid,
                    result = result
                })
            else
                log:debug("Standard worker exited unexpectedly, restarting", {
                    pid = pid,
                    result = result
                })
                restart_standard_worker_async(pid)
            end

            state.standard_workers[pid] = nil

        elseif cleanup_worker then
            local was_shutdown = state.shutdown_tracking.cleanup[pid] ~= nil

            if was_shutdown then
                state.shutdown_tracking.cleanup[pid] = nil
                log:debug("Cleanup worker shutdown complete", {
                    pid = pid,
                    result = result
                })
            else
                log:debug("Cleanup worker completed", {
                    pid = pid,
                    result = result
                })
            end

            state.cleanup_workers[pid] = nil
        end
    end

    local function handle_worker_crash(pid)
        local standard_worker = state.standard_workers[pid]
        local cleanup_worker = state.cleanup_workers[pid]

        if standard_worker then
            local was_shutdown = state.shutdown_tracking.standard[pid] ~= nil

            if was_shutdown then
                state.shutdown_tracking.standard[pid] = nil
                log:debug("Standard worker crashed during shutdown", { pid = pid })
            else
                log:debug("Standard worker crashed, restarting", { pid = pid })
                restart_standard_worker_async(pid)
            end

            state.standard_workers[pid] = nil

        elseif cleanup_worker then
            local was_shutdown = state.shutdown_tracking.cleanup[pid] ~= nil

            if was_shutdown then
                state.shutdown_tracking.cleanup[pid] = nil
                log:debug("Cleanup worker crashed during shutdown", { pid = pid })
            else
                log:debug("Cleanup worker crashed", { pid = pid })
            end

            state.cleanup_workers[pid] = nil
        end
    end

    log:debug("Starting initial workers", {
        worker_count = worker_count,
        batch_size = worker_batch_size,
        max_concurrent = worker_max_concurrent,
        startup_delay = worker_startup_delay,
        poll_interval = worker_poll_interval
    })

    for i = 1, worker_count do
        if i > 1 then
            time.sleep(worker_startup_delay)
        end

        local pid, spawn_err = spawn_standard_worker()
        if not pid then
            log:debug("Failed to start initial worker", {
                index = i,
                error = spawn_err
            })
        else
            log:debug("Started initial worker", {
                index = i,
                pid = pid
            })
        end
    end

    local cleanup_ticker = time.ticker(cleanup_interval)
    local events = process.events()

    spawn_cleanup_worker()

    local active_standard = 0
    for _ in pairs(state.standard_workers) do
        active_standard = active_standard + 1
    end

    log:info("Scheduler service started", {
        workers = active_standard,
        capacity = active_standard * worker_max_concurrent
    })

    while not state.shutting_down do
        local result = channel.select({
            cleanup_ticker:channel():case_receive(),
            events:case_receive()
        })

        if result.channel == cleanup_ticker:channel() then
            spawn_cleanup_worker()

        elseif result.channel == events then
            local event = result.value

            if event.kind == process.event.CANCEL then
                log:debug("Shutdown initiated")
                state.shutting_down = true

                for pid, worker_info in pairs(state.standard_workers) do
                    state.shutdown_tracking.standard[pid] = worker_info
                end
                for pid, worker_info in pairs(state.cleanup_workers) do
                    state.shutdown_tracking.cleanup[pid] = worker_info
                end

                local standard_count = 0
                local cleanup_count = 0
                for _ in pairs(state.shutdown_tracking.standard) do
                    standard_count = standard_count + 1
                end
                for _ in pairs(state.shutdown_tracking.cleanup) do
                    cleanup_count = cleanup_count + 1
                end

                log:debug("Cancelling all workers", {
                    standard_workers = standard_count,
                    cleanup_workers = cleanup_count,
                    timeout = CONST.SHUTDOWN_TIMEOUT
                })

                for pid, _ in pairs(state.shutdown_tracking.standard) do
                    log:debug("Cancelling standard worker", { pid = pid })
                    process.cancel(pid, CONST.SHUTDOWN_TIMEOUT)
                end

                for pid, _ in pairs(state.shutdown_tracking.cleanup) do
                    log:debug("Cancelling cleanup worker", { pid = pid })
                    process.cancel(pid, CONST.SHUTDOWN_TIMEOUT)
                end

            elseif event.kind == process.event.EXIT then
                handle_worker_exit(event.from, event.result)

            elseif event.kind == process.event.LINK_DOWN then
                handle_worker_crash(event.from)
            end
        end
    end

    cleanup_ticker:stop()

    local function count_pending()
        local standard_count = 0
        local cleanup_count = 0
        for _ in pairs(state.shutdown_tracking.standard) do
            standard_count = standard_count + 1
        end
        for _ in pairs(state.shutdown_tracking.cleanup) do
            cleanup_count = cleanup_count + 1
        end
        return standard_count, cleanup_count
    end

    local pending_standard, pending_cleanup = count_pending()
    log:debug("Waiting for graceful shutdown", {
        pending_standard = pending_standard,
        pending_cleanup = pending_cleanup,
        timeout = CONST.SHUTDOWN_TIMEOUT
    })

    local shutdown_start = time.now()
    local shutdown_timeout = time.parse_duration(CONST.SHUTDOWN_TIMEOUT)
    local shutdown_deadline = shutdown_start:add(shutdown_timeout)

    while pending_standard > 0 or pending_cleanup > 0 do
        if time.now():after(shutdown_deadline) then
            log:debug("Shutdown timeout reached, force terminating remaining workers")

            for pid, _ in pairs(state.shutdown_tracking.standard) do
                log:debug("Force terminating standard worker", { pid = pid })
                process.terminate(pid)
            end
            for pid, _ in pairs(state.shutdown_tracking.cleanup) do
                log:debug("Force terminating cleanup worker", { pid = pid })
                process.terminate(pid)
            end
            break
        end

        local remaining = shutdown_deadline:sub(time.now())
        local wait_time = time.parse_duration("100ms")
        if remaining:nanoseconds() < wait_time:nanoseconds() then
            wait_time = remaining
        end

        local timer = time.timer(wait_time)
        local shutdown_result = channel.select({
            events:case_receive(),
            timer:channel():case_receive()
        })
        timer:stop()

        if shutdown_result.channel == events then
            local event = shutdown_result.value
            if event.kind == process.event.EXIT then
                handle_worker_exit(event.from, event.result)
            elseif event.kind == process.event.LINK_DOWN then
                handle_worker_crash(event.from)
            end

            pending_standard, pending_cleanup = count_pending()
        end
    end

    log:debug("Scheduler root shutdown complete")
    return { status = "shutdown_complete" }
end

return { run = run }