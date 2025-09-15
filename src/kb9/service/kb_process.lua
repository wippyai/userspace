local time = require("time")
local logger = require("logger")
local contract = require("contract")
local json = require("json")
local consts = require("consts")
local store = require("store")
local embed_lib = require("embed_lib")

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local MAX_WORKERS = 50
local WORK_QUEUE_SIZE = 100
local RESULT_QUEUE_SIZE = 50
local DELETE_GRACE_PERIOD = "5s"

-- ============================================================================
-- WORKER POOL MANAGER
-- ============================================================================
local WorkerPool = {}
WorkerPool.__index = WorkerPool

function WorkerPool.new(max_workers, component_id, config, embed_binding)
    local pool = {
        max_workers = max_workers,
        component_id = component_id,
        config = config,
        embed_binding = embed_binding,

        -- Channels
        work_queue = channel.new(WORK_QUEUE_SIZE),
        result_queue = channel.new(RESULT_QUEUE_SIZE),
        shutdown_chan = channel.new(max_workers + 1), -- +1 for result collector

        -- State
        workers = {},
        result_collector = nil,
        deleting = false,
        stats = {
            work_processed = 0,
            batches_completed = 0
        }
    }

    return setmetatable(pool, WorkerPool)
end

function WorkerPool:start(log)
    log:debug("Starting worker pool", { max_workers = self.max_workers })

    -- Start result collector
    self.result_collector = coroutine.spawn(function()
        self:result_collector_loop(log)
    end)

    -- Start workers
    for i = 1, self.max_workers do
        self.workers[i] = coroutine.spawn(function()
            self:worker_loop(i, log)
        end)
    end

    log:debug("Worker pool started", {
        workers = #self.workers,
        result_collector = self.result_collector and "started" or "failed"
    })
end

function WorkerPool:stop(log)
    log:debug("Stopping worker pool gracefully")

    -- Signal all workers and result collector to stop
    for i = 1, self.max_workers + 1 do
        self.shutdown_chan:send(true)
    end

    -- Close channels
    self.work_queue:close()
    self.result_queue:close()
    self.shutdown_chan:close()

    log:debug("Worker pool stopped")
end

function WorkerPool:submit_work(work_item)
    if self.deleting then
        -- Reject work during deletion
        if work_item.reply_to then
            process.send(work_item.reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                success = false,
                error = "KB is being deleted",
                component_id = self.component_id
            })
        end
        return false
    end

    self.work_queue:send(work_item)
    return true
end

function WorkerPool:set_deleting()
    self.deleting = true
end

function WorkerPool:worker_loop(worker_id, log)
    log:debug("Worker started", { worker_id = worker_id })

    while true do
        local result = channel.select({
            self.work_queue:case_receive(),
            self.shutdown_chan:case_receive()
        })

        if result.channel == self.shutdown_chan then
            log:debug("Worker shutting down", { worker_id = worker_id })
            break
        end

        if result.channel == self.work_queue and result.ok then
            local work_item = result.value
            local work_result = self:process_work_item(work_item, worker_id, log)
            self.result_queue:send(work_result)
            self.stats.work_processed = self.stats.work_processed + 1
        end
    end

    log:debug("Worker stopped", { worker_id = worker_id })
end

function WorkerPool:process_work_item(work_item, worker_id, log)
    local command = work_item.command

    log:debug("Worker processing item", {
        worker_id = worker_id,
        work_id = work_item.work_id,
        command_type = command.type
    })

    local work_result = {
        work_id = work_item.work_id,
        batch_id = work_item.batch_id,
        worker_id = worker_id,
        reply_to = work_item.reply_to,
        success = true,
        ops = {},
        content_type = nil,
        processed_at = time.now()
    }

    -- Process different command types
    if command.type == consts.COMMAND_TYPES.EMBED_CONTENT then
        work_result = self:process_embed_content(command, work_result, log)

    elseif command.type == consts.COMMAND_TYPES.EMBED_REFERENCE then
        work_result = self:process_embed_reference(command, work_result, log)

    else
        -- All other commands are already ops - pass through
        work_result.ops = { command }
        work_result.content_type = "command"
        log:debug("Command passed as op", { command_type = command.type })
    end

    -- Log operations before sending to result collector
    if work_result.success and work_result.ops and #work_result.ops > 0 then
        log:debug("Worker completed processing", {
            worker_id = worker_id,
            ops_count = #work_result.ops,
            command_type = command.type
        })
    end

    return work_result
end

function WorkerPool:process_embed_content(command, work_result, log)
    local content = command.payload.content or ""
    local content_type = command.payload.content_type or "text/plain"
    local metadata = command.payload.metadata or {}
    local embed_options = self.config.embed_contract.options or {}

    if not self.config.embedding_model then
        work_result.success = false
        work_result.error = "Embedding model not configured"
        log:warn("Embedding model not configured")
        return work_result
    end

    local ops, err = embed_lib.process_content(
        content, content_type, metadata,
        self.embed_binding, self.component_id,
        self.config, embed_options
    )

    if err then
        work_result.success = false
        work_result.error = err
        log:warn("Embed content failed", { error = err })
    else
        work_result.ops = ops
        work_result.content_type = content_type
        log:debug("Embed content success", { ops_count = #ops })
    end

    return work_result
end

function WorkerPool:process_embed_reference(command, work_result, log)
    local reference = command.payload.reference
    local metadata = command.payload.metadata or {}
    local embed_options = self.config.embed_contract.options or {}

    local ops, err = embed_lib.process_reference(
        reference, metadata,
        self.embed_binding, self.component_id,
        self.config, embed_options
    )

    if err then
        work_result.success = false
        work_result.error = err
        log:warn("Embed reference failed", { error = err })
    else
        work_result.ops = ops
        work_result.content_type = "unknown"
        log:debug("Embed reference success", { ops_count = #ops })
    end

    return work_result
end

function WorkerPool:result_collector_loop(log)
    log:debug("Result collector started")
    local pending_batches = {}

    while true do
        local result = channel.select({
            self.result_queue:case_receive(),
            self.shutdown_chan:case_receive()
        })

        if result.channel == self.shutdown_chan then
            log:debug("Result collector shutting down")
            break
        end

        if result.channel == self.result_queue and result.ok then
            local work_result = result.value
            self:process_result(work_result, pending_batches, log)
        end
    end

    log:debug("Result collector stopped")
end

function WorkerPool:process_result(work_result, pending_batches, log)
    log:debug("Processing result", {
        work_id = work_result.work_id,
        batch_id = work_result.batch_id,
        success = work_result.success
    })

    -- Collect results for this batch
    if not pending_batches[work_result.batch_id] then
        pending_batches[work_result.batch_id] = {}
    end
    table.insert(pending_batches[work_result.batch_id], work_result)

    -- Process batch immediately (simplified batching)
    local batch_results = pending_batches[work_result.batch_id]
    pending_batches[work_result.batch_id] = nil

    -- Execute operations
    self:execute_batch_operations(batch_results, log)

    -- Send acknowledgments
    self:send_batch_acknowledgments(batch_results, log)

    self.stats.batches_completed = self.stats.batches_completed + 1
end

function WorkerPool:execute_batch_operations(batch_results, log)
    local all_ops = {}

    for _, result in ipairs(batch_results) do
        if result.success and result.ops then
            for _, op in ipairs(result.ops) do
                table.insert(all_ops, op)
            end
        end
    end

    if #all_ops > 0 then
        log:debug("Executing operations", { ops_count = #all_ops })

        local batch_store = store.new_batch(self.component_id)
        local store_result, store_err = batch_store:ops(all_ops):execute()

        if store_err then
            log:error("Store operation failed", { error = store_err })
        else
            log:debug("Operations completed", {
                ops_count = #all_ops,
                results_count = store_result and #store_result.results or 0
            })
        end
    end
end

function WorkerPool:send_batch_acknowledgments(batch_results, log)
    for _, result in ipairs(batch_results) do
        if result.reply_to then
            log:debug("Sending ACK", {
                reply_to = result.reply_to,
                success = result.success
            })

            process.send(result.reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                success = result.success,
                error = result.error,
                ops_executed = result.success and #(result.ops or {}) or 0,
                retrieved_content_type = result.content_type,
                component_id = self.component_id
            })
        end
    end
end

-- ============================================================================
-- KB PROCESS MANAGER
-- ============================================================================
local KBProcess = {}
KBProcess.__index = KBProcess

function KBProcess.new(component_id)
    local process = {
        component_id = component_id,
        config = nil,
        embed_binding = nil,
        query_binding = nil,
        worker_pool = nil,
        log = nil,
        deleting = false,
        stats = {
            commands_processed = 0,
            start_time = time.now()
        }
    }

    return setmetatable(process, KBProcess)
end

function KBProcess:load_config()
    self.log:debug("Loading configuration")

    local kb_store, err = store.get_component(self.component_id)
    if err then
        self.log:error("Component not found", { component_id = self.component_id, error = err })
        error("Component does not exist: " .. err)
    end

    local config_str = kb_store.config or "{}"
    local config = {}

    if type(config_str) == "string" then
        local parsed, parse_err = json.decode(config_str)
        if parse_err then
            self.log:error("Failed to parse config", { error = parse_err })
            error("Invalid component config: " .. parse_err)
        end
        config = parsed
    else
        config = config_str
    end

    -- Validate required contracts
    if not config.embed_contract or not config.embed_contract.binding_id then
        error("embed_contract.binding_id is required in KB configuration")
    end

    if not config.query_contract or not config.query_contract.binding_id then
        error("query_contract.binding_id is required in KB configuration")
    end

    -- Ensure options exist
    config.embed_contract.options = config.embed_contract.options or {}
    config.query_contract.options = config.query_contract.options or {}

    self.config = config
    self.embed_binding = config.embed_contract.binding_id
    self.query_binding = config.query_contract.binding_id

    self.log:debug("Config loaded", {
        embed_binding = self.embed_binding,
        query_binding = self.query_binding
    })
end

function KBProcess:start()
    self.log = logger:named("kb9.kb." .. self.component_id)

    self:load_config()

    -- Create and start worker pool
    self.worker_pool = WorkerPool.new(
        MAX_WORKERS,
        self.component_id,
        self.config,
        self.embed_binding
    )
    self.worker_pool:start(self.log)

    self.log:info("KB process starting", {
        component_id = self.component_id,
        embed_binding = self.embed_binding,
        query_binding = self.query_binding,
        max_workers = MAX_WORKERS
    })

    -- Send ready signal
    process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_READY, {
        pid = process.pid(),
        component_id = self.component_id
    })

    self.log:info("KB process ready")

    -- Start message handling
    self:message_loop()
end

function KBProcess:message_loop()
    local inbox = process.inbox()
    local events = process.events()

    while not self.deleting do
        local result = channel.select({
            inbox:case_receive(),
            events:case_receive()
        })

        if result.channel == events and result.value then
            local event = result.value
            if event.kind == process.event.CANCEL then
                self.log:debug("Cancel received")
                break
            end
        end

        if result.channel == inbox and result.ok then
            local msg = result.value
            local topic = msg:topic()
            local payload_data = msg:payload():data()

            if topic == consts.MESSAGE_TOPICS.COMMAND then
                self:handle_commands(payload_data)
            else
                self.log:warn("Unknown message topic", { topic = topic })
            end
        end
    end

    self.log:debug("Message loop ended")
end

function KBProcess:handle_commands(payload_data)
    local commands = payload_data.commands
    local reply_to = payload_data.reply_to

    if not commands or type(commands) ~= "table" or #commands == 0 then
        self.log:warn("Invalid command format - commands array required")
        if reply_to then
            process.send(reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                success = false,
                error = "Invalid command format - commands array required",
                component_id = self.component_id
            })
        end
        return
    end

    self.log:debug("Processing commands array", { commands_count = #commands })

    if self.deleting then
        self:reject_commands_during_deletion(commands)
        return
    end

    self.stats.commands_processed = self.stats.commands_processed + #commands
    local batch_id = "batch_" .. self.stats.commands_processed

    for i, command_wrapper in ipairs(commands) do
        local command = command_wrapper.command
        local cmd_reply_to = command_wrapper.reply_to

        -- Handle special commands directly
        if command.type == consts.COMMAND_TYPES.DELETE_KB then
            self:handle_delete_kb(cmd_reply_to)
            return -- Exit after deletion

        elseif command.type == consts.COMMAND_TYPES.INIT_EMBED then
            self:handle_init_embed(command, cmd_reply_to)

        elseif command.type == consts.COMMAND_TYPES.INIT_QUERY then
            self:handle_init_query(command, cmd_reply_to)

        else
            -- Regular work command - send to worker pool
            local work_item = {
                work_id = batch_id .. "_" .. i,
                batch_id = batch_id,
                command = command,
                reply_to = cmd_reply_to,
                submitted_at = time.now()
            }

            self.worker_pool:submit_work(work_item)
        end
    end
end

function KBProcess:reject_commands_during_deletion(commands)
    for _, command_wrapper in ipairs(commands) do
        if command_wrapper.reply_to then
            process.send(command_wrapper.reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                success = false,
                error = "KB is being deleted",
                component_id = self.component_id
            })
        end
    end
end

function KBProcess:handle_delete_kb(reply_to)
    self.log:info("DELETE_KB command received - starting deletion process")

    -- Set deletion flags
    self.deleting = true
    self.worker_pool:set_deleting()

    -- Wait grace period for current work to complete
    self.log:info("Waiting for workers to finish current work", { grace_period = DELETE_GRACE_PERIOD })
    local grace_timer = time.after(DELETE_GRACE_PERIOD)
    grace_timer:receive()
    self.log:info("Grace period completed - proceeding with deletion")

    -- Stop worker pool
    self.worker_pool:stop(self.log)

    -- Purge all KB data atomically
    self.log:info("Purging all KB data", { component_id = self.component_id })

    local purge_success = true
    local purge_error = nil
    local nodes_deleted = 0

    local function purge_operation()
        local batch_store = store.new_batch(self.component_id)
        local result, purge_err = batch_store:purge():execute()

        if purge_err then
            error("Purge failed: " .. purge_err)
        end

        -- Extract nodes deleted from results
        for _, res in ipairs(result.results) do
            if res.nodes_deleted then
                nodes_deleted = res.nodes_deleted
                break
            end
        end

        self.log:info("KB purge completed", {
            component_id = self.component_id,
            nodes_deleted = nodes_deleted
        })
    end

    local ok, err = cpcall(purge_operation)

    if not ok then
        purge_success = false
        purge_error = err
        self.log:error("KB purge failed", {
            component_id = self.component_id,
            error = err
        })
    end

    -- Send ACK to requester
    if reply_to then
        local ack_data = {
            success = purge_success,
            component_id = self.component_id,
            ops_executed = purge_success and nodes_deleted or 0
        }

        if not purge_success then
            ack_data.error = purge_error or "KB deletion failed"
        else
            ack_data.message = "KB deleted successfully"
        end

        self.log:debug("Sending DELETE_KB ACK", {
            reply_to = reply_to,
            success = purge_success
        })

        process.send(reply_to, consts.MESSAGE_TOPICS.KB_ASK, ack_data)
    end

    self.log:info("DELETE_KB completed - initiating final shutdown")
end

function KBProcess:handle_init_embed(command, reply_to)
    self.log:debug("Initializing embed config")

    local current_component, get_err = store.get_component(self.component_id)
    local current_config = {}

    if not get_err and current_component then
        if type(current_component.config) == "string" then
            local parsed, parse_err = json.decode(current_component.config)
            if not parse_err then
                current_config = parsed
            end
        elseif type(current_component.config) == "table" then
            current_config = current_component.config
        end
    end

    -- Update with new embed contract
    current_config.embed_contract = command.payload.embed_contract
    self.config.embed_contract = command.payload.embed_contract
    self.embed_binding = command.payload.embed_contract.binding_id

    -- Clear embed contract cache
    embed_lib.clear_cache()

    -- Persist updated config
    local store_result, store_err = store(self.component_id):component():update(current_config):execute()

    if reply_to then
        if store_err then
            self.log:error("Embed config store failed", { error = store_err })
            process.send(reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                success = false,
                error = "Failed to persist embed config: " .. store_err,
                ops_executed = 0,
                component_id = self.component_id
            })
        else
            self.log:debug("Embed config persisted successfully")
            process.send(reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                success = true,
                message = "Embed contract initialized and persisted",
                ops_executed = 1,
                component_id = self.component_id
            })
        end
    end
end

function KBProcess:handle_init_query(command, reply_to)
    self.log:debug("Initializing query config")

    local current_component, get_err = store.get_component(self.component_id)
    local current_config = {}

    if not get_err and current_component then
        if type(current_component.config) == "string" then
            local parsed, parse_err = json.decode(current_component.config)
            if not parse_err then
                current_config = parsed
            end
        elseif type(current_component.config) == "table" then
            current_config = current_component.config
        end
    end

    -- Update with new query contract
    current_config.query_contract = command.payload.query_contract
    self.config.query_contract = command.payload.query_contract
    self.query_binding = command.payload.query_contract.binding_id

    -- Persist updated config
    local store_result, store_err = store(self.component_id):component():update(current_config):execute()

    if reply_to then
        if store_err then
            self.log:error("Query config store failed", { error = store_err })
            process.send(reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                success = false,
                error = "Failed to persist query config: " .. store_err,
                ops_executed = 0,
                component_id = self.component_id
            })
        else
            self.log:debug("Query config persisted successfully")
            process.send(reply_to, consts.MESSAGE_TOPICS.KB_ASK, {
                success = true,
                message = "Query contract initialized and persisted",
                ops_executed = 1,
                component_id = self.component_id
            })
        end
    end
end

-- ============================================================================
-- MAIN RUN FUNCTION
-- ============================================================================
local function run(component_id)
    if not component_id then
        return { error = "Component ID is required" }
    end

    local kb_process = KBProcess.new(component_id)
    kb_process:start()

    local uptime = time.now():sub(kb_process.stats.start_time)
    kb_process.log:info("KB process shutdown complete", {
        uptime_seconds = uptime:seconds(),
        commands_processed = kb_process.stats.commands_processed
    })

    return {
        status = "shutdown_complete",
        stats = kb_process.stats
    }
end

return { run = run }