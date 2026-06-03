local time = require("time")
local logger = require("logger")
local exec = require("exec")
local json = require("json")
local mcp_consts = require("mcp_consts")

local REQUEST_TYPE_PING = "ping"
local REQUEST_TYPE_TOOLS_LIST = "tools_list"
local REQUEST_TYPE_TOOL_CALL = "tool_call"

local function run(args)
    if not args or not args.name then
        error(mcp_consts.ERRORS.MISSING_NAME)
    end

    local log = logger:named("mcp." .. args.name)
    log:info("Starting MCP exec server", {
        executable = args.executable,
        name = args.name,
        args = args.args,
        work_dir = args.work_dir,
        executor_id = args.executor_id
    })

    -- Register with process registry
    local registry_name = mcp_consts.REGISTRY.PREFIX .. args.name
    local register_success = process.registry.register(registry_name)
    if not register_success then
        log:error("Failed to register process", { name = registry_name })
        error(mcp_consts.ERRORS.REGISTRY_FAILED .. ": " .. registry_name)
    end

    -- Get executor and start process. Per-server executor_id wins over the
    -- module default, so a server can run on exec.native or exec.docker.
    local config = mcp_consts.get_config()
    local executor_id = args.executor_id or config.executor_id
    local executor = exec.get(executor_id)
    if not executor then
        log:error("Failed to get executor", { executor_id = executor_id })
        error(mcp_consts.ERRORS.EXECUTOR_FAILED)
    end

    -- Setup process options
    local proc_options = {}
    if args.work_dir then
        proc_options.work_dir = args.work_dir
    end
    if args.env then
        proc_options.env = args.env
    end

    -- Construct command. Empty executable runs the executor/image default
    -- entrypoint (e.g. a docker image whose CMD is the stdio MCP server).
    local command = args.executable or ""
    if args.args and #args.args > 0 then
        for _, arg in ipairs(args.args) do
            if string.find(arg, " ") then
                command = command .. ' "' .. arg .. '"'
            else
                command = command .. " " .. arg
            end
        end
    end

    log:info("Executing command", { command = command })

    local proc = executor:exec(command, proc_options)
    proc:start()

    -- Initialize state
    local request_id = mcp_consts.DEFAULTS.REQUEST_ID_START
    local running = true
    local initialized = false
    local initialization_error = nil
    local process_failed = false
    local tools = {}

    -- Pending request map: JSON-RPC id -> reply channel. Lets multiple
    -- in-flight requests (concurrent tool calls) be routed independently.
    local pending = {}

    -- Setup channels
    local inbox = process.inbox()
    local events = process.events()
    local stderr_lines = channel.new(10)
    local process_exit = channel.new(1)

    -- Stdout reader coroutine: route each response to its waiter by id.
    coroutine.spawn(function()
        log:debug("Starting stdout reader")
        local stdout_stream = proc:stdout_stream()
        local stdout_scanner = stdout_stream:scanner("lines")

        while stdout_scanner:scan() do
            local line = stdout_scanner:text()
            if line and line ~= "" then
                local response, parse_err = json.decode(line :: string)
                if response then
                    local waiter = response.id ~= nil and pending[response.id] or nil
                    if waiter then
                        pending[response.id] = nil
                        waiter:send(response)
                    else
                        log:debug("Unmatched/notification response", { id = response.id })
                    end
                else
                    log:warn("Failed to parse JSON", { error = parse_err, line = line })
                end
            end
        end

        local scan_err = stdout_scanner:err()
        if scan_err then
            log:error("Stdout scanner error", { error = scan_err })
        end

        stdout_stream:close()
        log:debug("Stdout reader completed")
    end)

    -- Stderr reader coroutine
    coroutine.spawn(function()
        local stderr_stream = proc:stderr_stream()
        local stderr_scanner = stderr_stream:scanner("lines")

        while stderr_scanner:scan() do
            local line = stderr_scanner:text()
            if line and line ~= "" then
                log:error("Process stderr", { line = line })
                stderr_lines:send(line)
            end
        end

        stderr_stream:close()
    end)

    -- Process exit monitor
    coroutine.spawn(function()
        local exit_code, err = proc:wait()

        log:warn("Process exited", { exit_code = exit_code, error = err, initialized = initialized })

        process_failed = true

        -- Unblock any waiters so in-flight requests fail fast.
        for id, waiter in pairs(pending) do
            pending[id] = nil
            waiter:send({ id = id, error = { message = "process exited" } })
        end

        if not initialized then
            initialization_error = string.format("Process exited during initialization (code: %s, error: %s)",
                tostring(exit_code), tostring(err or "none"))
        end

        process_exit:send({ exit_code = exit_code, error = err, during_init = not initialized })
        running = false
    end)

    -- Send a JSON-RPC notification (no id, no response expected).
    local function send_notification(method, params)
        if process_failed then return false, "Process failed" end
        local request = { jsonrpc = "2.0", method = method }
        if params then request.params = params end
        return proc:write_stdin(json.encode(request) .. "\n")
    end

    -- Send a JSON-RPC request and wait for its matching response. Safe to call
    -- from multiple coroutines concurrently (each reserves its own id+channel).
    local function request_response(method: string, params: table?, timeout_ms: number?)
        if process_failed then return nil, "Process failed" end

        local id = request_id
        request_id = request_id + 1

        local reply = channel.new(1)
        pending[id] = reply

        local request = { jsonrpc = "2.0", id = id, method = method }
        if params then request.params = params end

        local write_success, write_err = proc:write_stdin(json.encode(request) .. "\n")
        if not write_success then
            pending[id] = nil
            log:error("Failed to write to stdin", { error = write_err, method = method })
            return nil, mcp_consts.ERRORS.PROCESS_WRITE_FAILED
        end

        local timeout_channel = time.after(tostring(timeout_ms or mcp_consts.DEFAULTS.RESPONSE_TIMEOUT_MS) .. "ms")
        local result = channel.select({ reply:case_receive(), timeout_channel:case_receive() })
        if result.channel == timeout_channel then
            pending[id] = nil
            log:error("Response timeout", { expected_id = id, method = method })
            return nil, "Response timeout"
        end

        return (result.value :: { id: number?, result: table?, error: { message: string? }? }), nil
    end

    -- Client request handler (ping/tools_list are local; tool_call hits the server).
    local function handle_client_request(request)
        if request.type == REQUEST_TYPE_PING then
            if process_failed then return { error = "MCP process failed: " .. (initialization_error or "process exited") } end
            if not initialized then return { error = "MCP server not initialized" .. (initialization_error and (": " .. initialization_error) or "") } end
            return { success = true, pong = true }

        elseif request.type == REQUEST_TYPE_TOOLS_LIST then
            if process_failed then return { error = "MCP process failed: " .. (initialization_error or "process exited") } end
            if not initialized then return { error = "MCP server not initialized" .. (initialization_error and (": " .. initialization_error) or "") } end
            return { success = true, tools = tools }

        elseif request.type == REQUEST_TYPE_TOOL_CALL then
            if process_failed then return { error = "MCP process failed: " .. (initialization_error or "process exited") } end
            if not initialized then return { error = "MCP server not initialized" .. (initialization_error and (": " .. initialization_error) or "") } end

            local tool_params = { name = request.tool_name }
            if request.params and next(request.params) then
                tool_params.arguments = request.params
            end

            local tool_response, send_err = request_response(mcp_consts.OPERATIONS.TOOLS_CALL, tool_params,
                mcp_consts.DEFAULTS.TOOL_CALL_TIMEOUT_MS)
            if not tool_response then
                return { error = "Tool call failed: " .. (send_err or "unknown error") }
            end

            if tool_response.result then
                return { success = true, result = tool_response.result }
            else
                return { error = tool_response.error and tool_response.error.message or "Tool call failed" }
            end

        else
            return { error = "Unknown request type: " .. tostring(request.type) }
        end
    end

    local function reply_to_client(from_pid, request, response)
        if request.id and request.reply_to_topic and from_pid then
            local send_success = process.send(from_pid, request.reply_to_topic :: string, response)
            if not send_success then
                log:error("Failed to send response", { from_pid = from_pid, request_id = request.id })
            end
        else
            log:warn("Request missing required fields", { id = request.id, reply_to_topic = request.reply_to_topic })
        end
    end

    -- MCP initialization
    local function initialize_mcp()
        log:info("Starting MCP initialization")
        time.sleep(tostring(mcp_consts.DEFAULTS.INIT_DELAY_MS) .. "ms")

        local init_response, read_err = request_response(mcp_consts.OPERATIONS.INITIALIZE, {
            protocolVersion = config.protocol_version,
            capabilities = { tools = {} },
            clientInfo = config.client_info
        }, 10000)
        if not init_response then return false, "Initialize failed: " .. (read_err or "unknown error") end
        if not init_response.result then
            return false, "Initialize rejected: " .. (init_response.error and init_response.error.message or "unknown error")
        end
        log:info("Initialize successful", { capabilities = init_response.result.capabilities })

        send_notification(mcp_consts.OPERATIONS.INITIALIZED, table.create(0, 1))

        time.sleep(tostring(mcp_consts.DEFAULTS.TOOLS_REQUEST_DELAY_MS) .. "ms")

        local tools_response, tools_read_err = request_response(mcp_consts.OPERATIONS.TOOLS_LIST, nil, 10000)
        if not tools_response then return false, "Tools list failed: " .. (tools_read_err or "unknown error") end
        if not tools_response.result then
            return false, "Tools list rejected: " .. (tools_response.error and tools_response.error.message or "unknown error")
        end

        tools = tools_response.result.tools or {}
        log:info("Tools loaded", { count = #tools })
        return true, nil
    end

    -- Start initialization
    coroutine.spawn(function()
        local init_success, init_err = initialize_mcp()
        if init_success then
            initialized = true
            log:info("MCP exec server ready", { tools_count = #tools })
        else
            initialization_error = init_err
            log:error("MCP initialization failed", { error = init_err })
            error("MCP initialization failed: " .. init_err)
        end
    end)

    -- Main event loop
    while running do
        local result = channel.select({
            inbox:case_receive(),
            events:case_receive(),
            stderr_lines:case_receive(),
            process_exit:case_receive()
        })

        if result.channel == events then
            local event = result.value
            if event.kind == process.event.CANCEL then
                log:info("Received cancel signal")
                break
            end

        elseif result.channel == inbox then
            local message = result.value
            if message:topic() == mcp_consts.TOPICS.REQUEST then
                local from_pid = message:from()
                local request = message:payload():data()

                if request.type == REQUEST_TYPE_TOOL_CALL then
                    -- Handle tool calls off the main loop so concurrent calls
                    -- (multi-user) don't head-of-line block each other.
                    coroutine.spawn(function()
                        reply_to_client(from_pid, request, handle_client_request(request))
                    end)
                else
                    reply_to_client(from_pid, request, handle_client_request(request))
                end
            end

        elseif result.channel == stderr_lines then
            local stderr_line = result.value :: string
            if not initialized then
                initialization_error = (initialization_error or "") .. " | stderr: " .. stderr_line
            end

        elseif result.channel == process_exit then
            local exit_info = result.value :: { error: string?, exit_code: number? }
            log:error("Process exit detected", exit_info)
            if initialized then
                error("MCP process crashed: " .. tostring(exit_info.error or "exit code " .. tostring(exit_info.exit_code)))
            else
                error("MCP process failed during initialization: " .. (initialization_error or "unknown error"))
            end
        end
    end

    log:info("Shutting down MCP exec server")
    running = false
    proc:close()
    executor:release()

    return {
        status = "completed",
        initialized = initialized,
        initialization_error = initialization_error,
        tools_count = #tools
    }
end

return { run = run }
