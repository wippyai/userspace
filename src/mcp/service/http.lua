local logger = require("logger")
local http_client = require("http_client")
local json = require("json")
local time = require("time")
local exec = require("exec")
local mcp_consts = require("mcp_consts")

-- MCP server manager for streamable-HTTP transport. Mirrors service/exec's
-- client message interface (request/reply_to_topic), but speaks MCP JSON-RPC to
-- a configured URL instead of a child process's stdio.
--
-- If args.executor_id is set, this also launches the HTTP server itself via that
-- executor (e.g. an exec.docker executor running an --http MCP image) and holds
-- it for the process lifetime, then connects to args.url. That keeps a long-lived
-- HTTP MCP server fully managed without coupling to userspace/docker.

local REQUEST_TYPE_PING = "ping"
local REQUEST_TYPE_TOOLS_LIST = "tools_list"
local REQUEST_TYPE_TOOL_CALL = "tool_call"

-- Streamable-HTTP responses are either plain JSON or an SSE "data: {json}" line.
local function parse_rpc(raw: string?)
    if not raw or raw == "" then return nil end
    local trimmed = raw:match("^%s*(.-)%s*$") or raw
    if trimmed:sub(1, 1) == "{" then
        local decoded, _ = json.decode(trimmed)
        return decoded
    end
    for line in raw:gmatch("[^\n]+") do
        local data = line:match("^data:%s*(.+)$")
        if data then
            local decoded, _ = json.decode(data)
            if decoded then return decoded end
        end
    end
    return nil
end

local function run(args)
    if not args or not args.name then
        error(mcp_consts.ERRORS.MISSING_NAME)
    end
    if not args.url or args.url == "" then
        error("Missing MCP server url")
    end

    local url = args.url
    local log = logger:named("mcp." .. args.name)
    log:info("Starting MCP http server", { name = args.name, url = url })

    local registry_name = mcp_consts.REGISTRY.PREFIX .. args.name
    if not process.registry.register(registry_name) then
        error(mcp_consts.ERRORS.REGISTRY_FAILED .. ": " .. registry_name)
    end

    -- Optionally launch the HTTP server via an executor (e.g. exec.docker running
    -- an --http MCP image) and hold it for this process's lifetime.
    local held_proc = nil
    local held_executor = nil
    if args.executor_id and args.executor_id ~= "" then
        local command = args.executable or ""
        if args.args and #args.args > 0 then
            for _, a in ipairs(args.args) do
                command = command .. (string.find(a, " ") and (' "' .. a .. '"') or (" " .. a))
            end
        end
        held_executor = exec.get(args.executor_id)
        if not held_executor then
            error(mcp_consts.ERRORS.EXECUTOR_FAILED .. ": " .. tostring(args.executor_id))
        end
        local proc, proc_err = held_executor:exec(command)
        if not proc then
            held_executor:release()
            error("Failed to launch http server: " .. tostring(proc_err))
        end
        held_proc = proc
        proc:start()
        log:info("Launched http MCP server container", { executor = args.executor_id, command = command })
    end

    local function cleanup()
        if held_proc then held_proc:close() end
        if held_executor then held_executor:release() end
    end

    local config = mcp_consts.get_config()
    local request_id = mcp_consts.DEFAULTS.REQUEST_ID_START
    local initialized = false
    local initialization_error = nil
    local tools = {}

    local function rpc(method, params, is_notification, timeout)
        local body: table = { jsonrpc = "2.0", method = method }
        if not is_notification then
            body.id = request_id
            request_id = request_id + 1
        end
        if params then body.params = params end

        local response, err = http_client.post(url, {
            headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json, text/event-stream",
            },
            body = json.encode(body),
            timeout = timeout or "60s",
        })
        if err then return nil, tostring(err) end
        if is_notification then return true, nil end

        local status = response.status_code or 0
        if status < 200 or status >= 300 then
            return nil, "HTTP " .. tostring(status)
        end

        local decoded = parse_rpc(response.body :: string?)
        if not decoded then return nil, mcp_consts.ERRORS.INVALID_RESPONSE end
        return (decoded :: { result: table?, error: { message: string? }? }), nil
    end

    local function initialize_mcp()
        local init, err = rpc(mcp_consts.OPERATIONS.INITIALIZE, {
            protocolVersion = config.protocol_version,
            capabilities = { tools = {} },
            clientInfo = config.client_info,
        }, false, "10s")
        if not init then return false, "Initialize failed: " .. (err or "unknown error") end
        if not init.result then
            return false, "Initialize rejected: " .. (init.error and init.error.message or "unknown error")
        end

        rpc(mcp_consts.OPERATIONS.INITIALIZED, nil, true)

        local tl, tl_err = rpc(mcp_consts.OPERATIONS.TOOLS_LIST, nil, false, "10s")
        if not tl then return false, "Tools list failed: " .. (tl_err or "unknown error") end
        if tl.result then tools = tl.result.tools or {} end
        log:info("Tools loaded", { count = #tools })
        return true, nil
    end

    local function handle_client_request(request)
        if not initialized then
            return { error = "MCP server not initialized" ..
                (initialization_error and (": " .. initialization_error) or "") }
        end

        if request.type == REQUEST_TYPE_PING then
            return { success = true, pong = true }

        elseif request.type == REQUEST_TYPE_TOOLS_LIST then
            return { success = true, tools = tools }

        elseif request.type == REQUEST_TYPE_TOOL_CALL then
            local tool_params: table = { name = request.tool_name }
            if request.params and next(request.params) then
                tool_params.arguments = request.params
            end
            local resp, err = rpc(mcp_consts.OPERATIONS.TOOLS_CALL, tool_params, false,
                tostring(mcp_consts.DEFAULTS.TOOL_CALL_TIMEOUT_MS) .. "ms")
            if not resp then return { error = "Tool call failed: " .. (err or "unknown error") } end
            if resp.result then return { success = true, result = resp.result } end
            return { error = resp.error and resp.error.message or "Tool call failed" }

        else
            return { error = "Unknown request type: " .. tostring(request.type) }
        end
    end

    local function reply_to_client(from_pid, request, response)
        if request.id and request.reply_to_topic and from_pid then
            process.send(from_pid, request.reply_to_topic :: string, response)
        end
    end

    -- Connect in the background, retrying while a freshly launched server binds
    -- its port. Does not relaunch (avoids container/port leaks on a slow start).
    coroutine.spawn(function()
        local attempts = held_proc and 15 or 5
        for i = 1, attempts do
            local ok, err = initialize_mcp()
            if ok then
                initialized = true
                log:info("MCP http server ready", { tools_count = #tools })
                return
            end
            initialization_error = err
            log:warn("MCP init attempt failed; retrying", { attempt = i, error = err })
            time.sleep("2s")
        end
        log:error("MCP initialization failed after retries", { error = initialization_error })
    end)

    -- If we launched the server and it exits, fail so the supervisor respawns us
    -- (cleanup first so the dead container/port is released before relaunch).
    if held_proc then
        coroutine.spawn(function()
            held_proc:wait()
            log:error("http MCP server exited")
            cleanup()
            error("http MCP server exited")
        end)
    end

    local events = process.events()
    local inbox = process.inbox()

    while true do
        local result = channel.select({ inbox:case_receive(), events:case_receive() })

        if result.channel == events then
            if result.value.kind == process.event.CANCEL then
                log:info("Received cancel signal")
                break
            end
        elseif result.channel == inbox then
            local message = result.value
            if message:topic() == mcp_consts.TOPICS.REQUEST then
                local from_pid = message:from()
                local request = message:payload():data()
                -- Handle off the main loop so concurrent calls don't block.
                coroutine.spawn(function()
                    reply_to_client(from_pid, request, handle_client_request(request))
                end)
            end
        end
    end

    cleanup()
    return { status = "completed", initialized = initialized, tools_count = #tools }
end

return { run = run }
