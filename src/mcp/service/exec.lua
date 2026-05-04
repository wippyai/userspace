local time = require("time")
local logger = require("logger")
local exec = require("exec")
local json = require("json")
local mcp_consts = require("mcp_consts")

local REQUEST_TYPE_PING = "ping"
local REQUEST_TYPE_TOOLS_LIST = "tools_list"
local REQUEST_TYPE_TOOL_CALL = "tool_call"

local function run(args)
    if not args or not args.executable then
        error(mcp_consts.ERRORS.MISSING_EXECUTABLE)
    end

    if not args.name then
        error(mcp_consts.ERRORS.MISSING_NAME)
    end

    local executable = tostring(args.executable)
    local name = tostring(args.name)

    local log = logger:named("mcp." .. name)
    log:info("Starting MCP exec server", {
        executable = executable,
        name = name,
        args = args.args,
        work_dir = args.work_dir
    })

    -- Register with process registry
    local registry_name = mcp_consts.REGISTRY.PREFIX .. name
    local register_success = process.registry.register(registry_name)
    if not register_success then
        log:error("Failed to register process", { name = registry_name })
        error(mcp_consts.ERRORS.REGISTRY_FAILED .. ": " .. registry_name)
    end

    -- Get executor and start process
    local config = mcp_consts.get_config()
    local executor = exec.get(config.executor_id)
    if not executor then
        log:error("Failed to get executor", { executor_id = config.executor_id })
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

    -- Construct command
    local command = executable
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

    -- Setup channels
    local inbox = process.inbox()
    local events = process.events()
    local stdout_responses = channel.new(10)
    local stderr_lines = channel.new(10)
    local process_exit = channel.new(1)

    -- Stdout reader coroutine
    coroutine.spawn(function()
        log:debug("Starting stdout reader")
        local stdout_stream = proc:stdout_stream()
        local stdout_scanner = stdout_stream:scanner("lines")

        while stdout_scanner:scan() do
            local line = stdout_scanner:text()
            if line and line ~= "" then
                log:debug("Stdout line", { line = line })

                local response, parse_err = json.decode(tostring(line))
                if response then
                    log:debug("Parsed JSON response", {
                        id = response.id,
                        has_result = response.result ~= nil,
                        has_error = response.error ~= nil
                    })
                    stdout_responses:send(response)
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
        log:debug("Starting stderr reader")
        local stderr_stream = proc:stderr_stream()
        local stderr_scanner = stderr_stream:scanner("lines")

        while stderr_scanner:scan() do
            local line = stderr_scanner:text()
            if line and line ~= "" then
                log:error("Process stderr", { line = line })
                stderr_lines:send(line)
            end
        end

        local scan_err = stderr_scanner:err()
        if scan_err then
            log:error("Stderr scanner error", { error = scan_err })
        end

        stderr_stream:close()
        log:debug("Stderr reader completed")
    end)

    -- Process exit monitor
    coroutine.spawn(function()
        log:debug("Starting process exit monitor")
        local exit_code, err = proc:wait()

        log:warn("Process exited", {
            exit_code = exit_code,
            error = err,
            initialized = initialized
        })

        process_failed = true

        if not initialized then
            initialization_error = string.format("Process exited during initialization (code: %s, error: %s)",
                tostring(exit_code), tostring(err or "none"))
        end

        process_exit:send({
            exit_code = exit_code,
            error = err,
            during_init = not initialized
        })

        running = false
        log:debug("Process exit monitor completed")
    end)

    -- JSON-RPC functions
    local function send_json_rpc(method, params, is_notification)
        if process_failed then
            return nil, "Process failed"
        end

        local request = {
            jsonrpc = "2.0",
            method = method
        }

        if not is_notification then
            request.id = request_id
            request_id = request_id + 1
        end

        if params then
            request.params = params
        end

        local json_str = json.encode(request)
        log:debug("Sending JSON-RPC", {
            method = method,
            id = request.id,
            json_length = #json_str
        })

        local write_success, write_err = proc:write_stdin(json_str .. "\n")
        if not write_success then
            log:error("Failed to write to stdin", { error = write_err, method = method })
            return nil, mcp_consts.ERRORS.PROCESS_WRITE_FAILED
        end

        return request.id
    end

    local function wait_for_response(expected_id, timeout_ms)
        timeout_ms = timeout_ms or 5000
        local timeout_channel = time.after(tostring(timeout_ms) .. "ms")

        while running and not process_failed do
            local result = channel.select({
                stdout_responses:case_receive(),
                timeout_channel:case_receive()
            })

            if result.channel == timeout_channel then
                log:error("Response timeout", { expected_id = expected_id })
                return nil, "Response timeout"
            end

            local response = result.value :: any
            if response.error then
                return nil, response.error
            end

            if expected_id == nil or response.id == expected_id then
                return response, nil
            end

            log:debug("Unexpected response", { received_id = response.id, expected_id = expected_id })
        end

        return nil, "Process failed or stopped"
    end

    -- Client request handler
    local function handle_client_request(request)
        log:debug("Handling client request", {
            type = request.type,
            id = request.id,
            initialized = initialized,
            process_failed = process_failed
        })

        if request.type == REQUEST_TYPE_PING then
            if process_failed then
                return { error = "MCP process failed: " .. (initialization_error or "process exited") }
            end
            if not initialized then
                return {
                    error = "MCP server not initialized" ..
                        (initialization_error and (": " .. initialization_error) or "")
                }
            end
            return { success = true, pong = true }

        elseif request.type == REQUEST_TYPE_TOOLS_LIST then
            if process_failed then
                return { error = "MCP process failed: " .. (initialization_error or "process exited") }
            end
            if not initialized then
                return {
                    error = "MCP server not initialized" ..
                        (initialization_error and (": " .. initialization_error) or "")
                }
            end
            return { success = true, tools = tools }

        elseif request.type == REQUEST_TYPE_TOOL_CALL then
            if process_failed then
                return { error = "MCP process failed: " .. (initialization_error or "process exited") }
            end
            if not initialized then
                return {
                    error = "MCP server not initialized" ..
                        (initialization_error and (": " .. initialization_error) or "")
                }
            end

            local tool_params = {
                name = request.tool_name
            }

            -- Only include arguments if params exist and are not empty
            if request.params and next(request.params) then
                tool_params.arguments = request.params
            end

            local tool_id, send_err = send_json_rpc(mcp_consts.OPERATIONS.TOOLS_CALL, tool_params)
            if not tool_id then
                return { error = "Failed to call tool: " .. (send_err or "unknown error") }
            end

            local tool_response, read_err = wait_for_response(tool_id, mcp_consts.DEFAULTS.TOOL_CALL_TIMEOUT_MS)
            tool_response = tool_response :: any
            if not tool_response then
                return { error = "Tool call failed: " .. (read_err or "unknown error") }
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

    -- MCP initialization
    local function initialize_mcp()
        log:info("Starting MCP initialization")

        time.sleep(tostring(mcp_consts.DEFAULTS.INIT_DELAY_MS) .. "ms")

        local init_params = {
            protocolVersion = config.protocol_version,
            capabilities = { tools = {} },
            clientInfo = config.client_info
        }

        local init_id, send_err = send_json_rpc(mcp_consts.OPERATIONS.INITIALIZE, init_params)
        if not init_id then
            return false, "Failed to send initialize: " .. (send_err or "unknown error")
        end

        local init_response, read_err = wait_for_response(init_id, 10000)
        init_response = init_response :: any
        if not init_response then
            return false, "Initialize failed: " .. (read_err or "unknown error")
        end

        if not init_response.result then
            return false,
                "Initialize rejected: " .. (init_response.error and init_response.error.message or "unknown error")
        end

        log:info("Initialize successful", { capabilities = init_response.result.capabilities })

        send_json_rpc(mcp_consts.OPERATIONS.INITIALIZED, table.create(0,1), true)

        time.sleep(tostring(mcp_consts.DEFAULTS.TOOLS_REQUEST_DELAY_MS) .. "ms")

        local tools_id, tools_send_err = send_json_rpc(mcp_consts.OPERATIONS.TOOLS_LIST)
        if not tools_id then
            return false, "Failed to send tools_list: " .. (tools_send_err or "unknown error")
        end

        local tools_response, tools_read_err = wait_for_response(tools_id, 10000)
        tools_response = tools_response :: any
        if not tools_response then
            return false, "Tools list failed: " .. (tools_read_err or "unknown error")
        end

        if not tools_response.result then
            return false,
                "Tools list rejected: " .. (tools_response.error and tools_response.error.message or "unknown error")
        end

        tools = tools_response.result.tools or {}
        log:info("Tools loaded", { count = #tools })

        for _, tool in ipairs(tools) do
            log:debug("Tool available", { name = tool.name, description = tool.description })
        end

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
            local topic = message:topic()

            -- Only handle messages sent to the REQUEST topic
            if topic == mcp_consts.TOPICS.REQUEST then
                local from_pid = message:from()
                local request = message:payload():data()

                log:debug("Processing client request", {
                    type = request.type,
                    id = request.id,
                    from_pid = from_pid,
                    reply_to_topic = request.reply_to_topic
                })

                local response = handle_client_request(request)

                local reply_to_topic = request.reply_to_topic
                if request.id and type(reply_to_topic) == "string" and from_pid then
                    log:debug("Sending response", {
                        from_pid = from_pid,
                        reply_to_topic = reply_to_topic,
                        request_id = request.id
                    })

                    local send_success = process.send(from_pid, reply_to_topic, response)

                    if not send_success then
                        log:error("Failed to send response", {
                            from_pid = from_pid,
                            reply_to_topic = reply_to_topic,
                            request_id = request.id
                        })
                    end
                else
                    log:warn("Request missing required fields", {
                        id = request.id,
                        reply_to_topic = request.reply_to_topic,
                        from_pid = from_pid
                    })
                end
            end

        elseif result.channel == stderr_lines then
            local stderr_line = result.value
            if not initialized then
                initialization_error = (initialization_error or "") .. " | stderr: " .. tostring(stderr_line)
            end

        elseif result.channel == process_exit then
            local exit_info = result.value
            log:error("Process exit detected", exit_info)

            -- Process failed - trigger supervisor restart
            if initialized then
                log:error("MCP process crashed after initialization - triggering restart")
                error("MCP process crashed: " .. tostring(exit_info.error or "exit code " .. tostring(exit_info.exit_code)))
            else
                log:error("MCP process failed during initialization - triggering restart")
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
