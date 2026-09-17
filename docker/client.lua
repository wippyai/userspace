local http_client = require("http_client")
local json = require("json")
local time = require("time")

local DOCKER_SOCKETS = {
    "/var/run/docker.sock",
    "/Users/Shared/Docker/docker.sock",
    "/tmp/docker.sock",
    "/run/docker.sock",
}

local DEFAULT_TIMEOUT = "30s"

local function encode_query(params: {[string]: string})
    local parts = {}
    for key, value in pairs(params) do
        table.insert(parts, key .. "=" .. http_client.encode_uri(tostring(value)))
    end
    if #parts == 0 then
        return ""
    end
    return "?" .. table.concat(parts, "&")
end

-- Decodes a response body only when the daemon declares it as JSON. Log,
-- archive and plain-text bodies are returned untouched.
local function parse_response(body: any, headers: {[string]: string}?)
    if not body then
        return nil
    end
    if type(body) == "table" then
        return body
    end
    local content_type = headers and headers["Content-Type"]
    if type(body) == "string" and content_type and content_type:find("json", 1, true) then
        local parsed, err = json.decode(body)
        if not err and parsed ~= nil then
            return parsed
        end
    end
    return body
end

local function make_request(sock: string, method: string, endpoint: string, options: table?)
    local opts = options or {}

    local url = "http://docker" .. endpoint
    if opts.query then
        url = url .. encode_query(opts.query)
    end

    local encoded_body: string = ""
    if opts.raw_body then
        encoded_body = tostring(opts.raw_body)
    elseif opts.body then
        if type(opts.body) == "table" then
            encoded_body = json.encode(opts.body)
        else
            encoded_body = tostring(opts.body)
        end
    end

    local hdrs: {[string]: string} = opts.headers or { ["Content-Type"] = "application/json" }
    local timeout: string = tostring(opts.timeout or DEFAULT_TIMEOUT)

    local response, err
    if method == "GET" then
        response, err = http_client.get(url, {
            unix_socket = sock, timeout = timeout, headers = hdrs, body = encoded_body,
        })
    elseif method == "POST" then
        response, err = http_client.post(url, {
            unix_socket = sock, timeout = timeout, headers = hdrs, body = encoded_body,
        })
    elseif method == "DELETE" then
        response, err = http_client.request("DELETE", url, {
            unix_socket = sock, timeout = timeout, headers = hdrs, body = encoded_body,
        })
    elseif method == "PUT" then
        response, err = http_client.request("PUT", url, {
            unix_socket = sock, timeout = timeout, headers = hdrs, body = encoded_body,
        })
    else
        return nil, "unsupported method: " .. method
    end

    if err then
        return nil, err
    end

    local result = {
        status_code = response.status_code,
        body = parse_response(response.body, response.headers),
        raw_body = response.body,
        headers = response.headers,
    }

    if response.status_code >= 400 then
        local error_msg = "HTTP " .. response.status_code
        if result.body and result.body.message then
            error_msg = error_msg .. ": " .. result.body.message
        end
        return result, error_msg
    end

    return result, nil
end

-- Incremental decoder for the Docker multiplexed log stream.
-- Each frame: [1 byte stream type][3 bytes padding][4 bytes big-endian size][payload]
-- stream type: 2 = stderr, anything else = stdout. A frame boundary ends a line;
-- newlines inside a payload split it further and empty lines are dropped. With
-- timestamps, every frame payload starts with an RFC3339Nano stamp and a space.
type LogEntry = {stream: string, line: string, ts: string?}

type LogDecoder = {
    push: (self: LogDecoder, chunk: string?) -> {LogEntry},
}

local function new_log_decoder(opts: {timestamps: boolean?}?): LogDecoder
    local timestamps = opts ~= nil and opts.timestamps == true
    local pending = ""
    local decoder = {}

    function decoder:push(chunk: string?): {LogEntry}
        local entries: {LogEntry} = {}
        if chunk and chunk ~= "" then
            pending = pending .. chunk
        end
        local data = pending
        local len = #data
        local pos = 1

        while pos + 7 <= len do
            local b1 = string.byte(data, pos + 4)
            local b2 = string.byte(data, pos + 5)
            local b3 = string.byte(data, pos + 6)
            local b4 = string.byte(data, pos + 7)
            local size = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
            if pos + 7 + size > len then
                break
            end
            local stream = (string.byte(data, pos) == 2) and "stderr" or "stdout"
            local payload = data:sub(pos + 8, pos + 7 + size)
            pos = pos + 8 + size

            local ts: string? = nil
            if timestamps then
                local space = payload:find(" ", 1, true)
                if space then
                    ts = payload:sub(1, space - 1)
                    payload = payload:sub(space + 1)
                end
            end

            local line_start = 1
            local payload_len = #payload
            while line_start <= payload_len do
                local nl = payload:find("\n", line_start, true)
                local line_end = nl and (nl - 1) or payload_len
                if line_end >= line_start then
                    table.insert(entries, { stream = stream, line = payload:sub(line_start, line_end), ts = ts })
                end
                if not nl then break end
                line_start = nl + 1
            end
        end

        pending = pos > 1 and data:sub(pos) or data
        return entries
    end

    return decoder :: LogDecoder
end

-- Parse a complete Docker multiplexed log body. A trailing truncated frame is dropped.
local function parse_logs(raw: string?): {LogEntry}
    if not raw or raw == "" then
        return {}
    end
    return new_log_decoder():push(tostring(raw))
end

-- Converts a Docker RFC3339Nano log timestamp to the "seconds.nanoseconds" form
-- accepted by the logs `since` parameter.
local function since_of(ts: string): string?
    local t, err = time.parse(time.RFC3339NANO, ts)
    if err or not t then
        return nil
    end
    return string.format("%d.%09d", t:unix(), t:nanosecond())
end

-- Tracks the last delivered log timestamp so a follow stream reopened with
-- since=<last timestamp> skips the lines it replays. Docker timestamps are fixed
-- width UTC, so they order lexicographically.
type LogCursor = {
    accept: (self: LogCursor, entry: {ts: string?}) -> boolean,
    reconnect: (self: LogCursor) -> (),
    since: (self: LogCursor) -> string?,
}

local function new_log_cursor(): LogCursor
    local last_ts: string? = nil
    local seen_at_last: number = 0
    local replay_skip: number = 0
    local cursor = {}

    function cursor:accept(entry: {ts: string?}): boolean
        local ts = entry.ts
        if ts == nil then
            return true
        end
        if last_ts == nil or ts > last_ts then
            last_ts = ts
            seen_at_last = 1
            replay_skip = 0
            return true
        end
        if ts < last_ts then
            return false
        end
        if replay_skip > 0 then
            replay_skip = replay_skip - 1
            return false
        end
        seen_at_last = seen_at_last + 1
        return true
    end

    function cursor:reconnect()
        replay_skip = seen_at_last
    end

    function cursor:since(): string?
        if last_ts == nil then
            return nil
        end
        return since_of(last_ts)
    end

    return cursor :: LogCursor
end

-- Parse JSON-per-line streamed responses from pull/build endpoints
local function parse_stream_lines(raw: any)
    if not raw then
        return {}
    end
    local data = tostring(raw)
    local lines = {}
    local pos = 1
    while pos <= #data do
        local nl = data:find("\n", pos, true)
        local line_end = nl and (nl - 1) or #data
        local line = data:sub(pos, line_end)
        if line ~= "" then
            if line:sub(-1) == "\r" then
                line = line:sub(1, -2)
            end
            local parsed, parse_err = json.decode(line)
            if not parse_err and parsed then
                table.insert(lines, parsed)
            end
        end
        if not nl then break end
        pos = nl + 1
    end
    return lines
end

local docker = {}

local cached_socket: string? = nil

function docker.new(socket_path: string?)
    local sock: string
    if not socket_path then
        if cached_socket then
            local _, ping_err = make_request(cached_socket, "GET", "/_ping", { timeout = "2s" })
            if not ping_err then
                sock = cached_socket
            else
                cached_socket = nil
                sock = ""
            end
        end
        if not sock or sock == "" then
            local found: string? = nil
            for _, path in ipairs(DOCKER_SOCKETS) do
                local response, err = http_client.get("http://docker/_ping", {
                    unix_socket = path,
                    timeout = "5s",
                })
                if not err and response.status_code == 200 then
                    found = path
                    break
                end
            end
            if not found then
                return nil, "no Docker socket found"
            end
            sock = found
            cached_socket = found
        end
    else
        local _, err = make_request(socket_path, "GET", "/_ping", { timeout = "5s" })
        if err then
            return nil, "connection failed: " .. tostring(err)
        end
        sock = socket_path
    end

    local client = {}

    function client:create_container(config: table, params: {name: string?}?)
        local p = params or {}
        local query = {}
        if p.name then
            query.name = p.name
        end
        local opts = { body = config }
        if next(query) then
            opts.query = query
        end
        local result, req_err = make_request(sock, "POST", "/containers/create", opts)
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:start_container(id: string)
        local _, req_err = make_request(sock, "POST", "/containers/" .. id .. "/start")
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:stop_container(id: string, timeout: number?)
        local query = {}
        if timeout then
            query.t = timeout
        end
        local opts = {}
        if next(query) then
            opts.query = query
        end
        local _, req_err = make_request(sock, "POST", "/containers/" .. id .. "/stop", opts)
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:wait_container(id: string)
        local result, req_err = make_request(sock, "POST", "/containers/" .. id .. "/wait", {
            timeout = "600s",
        })
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:inspect_container(id: string)
        local result, req_err = make_request(sock, "GET", "/containers/" .. id .. "/json")
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:remove_container(id: string, force: boolean?)
        local query = { v = "true" }
        if force then
            query.force = "true"
        end
        local _, req_err = make_request(sock, "DELETE", "/containers/" .. id, {
            query = query,
        })
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:list_containers(filters: table?)
        local query = { all = "true" }
        if filters then
            query.filters = json.encode(filters)
        end
        local result, req_err = make_request(sock, "GET", "/containers/json", {
            query = query,
        })
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:get_logs(id: string, options: {since: number?, tail: string?, timeout: string?}?)
        local log_opts = options or {}
        local query = {
            stdout = "true",
            stderr = "true",
        }
        if log_opts.since then
            query.since = tostring(log_opts.since)
        end
        if log_opts.tail then
            query.tail = tostring(log_opts.tail)
        end
        local result, req_err = make_request(sock, "GET", "/containers/" .. id .. "/logs", {
            query = query,
            timeout = log_opts.timeout or "10s",
        })
        if req_err or not result then
            return nil, req_err
        end
        return result.raw_body, nil
    end

    -- Opens a follow stream of the container's stdout/stderr with per-frame
    -- timestamps. The stream ends when the container stops, when `timeout`
    -- elapses, or when the connection drops. Returns the stream reader.
    function client:follow_logs(id: string, options: {since: string?, timeout: string?}?)
        local o = options or {}
        local query: {[string]: string} = {
            stdout = "true",
            stderr = "true",
            follow = "true",
            timestamps = "true",
        }
        if o.since then
            query.since = tostring(o.since)
        end
        local response, err = http_client.get("http://docker/containers/" .. id .. "/logs" .. encode_query(query), {
            unix_socket = sock,
            timeout = o.timeout or "1h",
            stream = true,
        })
        if err then
            return nil, err
        end
        local reader = response.stream
        if response.status_code >= 400 then
            local message = ""
            if reader then
                message = tostring(reader:read(8192) or "")
                reader:close()
            end
            local parsed = parse_response(message, response.headers)
            local detail = type(parsed) == "table" and parsed.message or message
            return nil, "HTTP " .. response.status_code .. ": " .. tostring(detail)
        end
        if not reader then
            return nil, "logs stream unavailable"
        end
        return reader, nil
    end

    function client:list_images(filters: table?)
        local query = {}
        if filters then
            query.filters = json.encode(filters)
        end
        local result, req_err = make_request(sock, "GET", "/images/json", {
            query = query,
        })
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:inspect_image(name: string)
        local result, req_err = make_request(sock, "GET", "/images/" .. name .. "/json")
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:remove_image(name: string, force: boolean?)
        local query = { noprune = "false" }
        if force then
            query.force = "true"
        end
        local result, req_err = make_request(sock, "DELETE", "/images/" .. name, {
            query = query,
        })
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:pull_image(from: string, tag: string?)
        local query: {[string]: string} = { fromImage = from }
        if tag then
            query.tag = tag
        end
        local result, req_err = make_request(sock, "POST", "/images/create", {
            query = query,
            timeout = "120s",
        })
        if req_err or not result then
            return nil, req_err
        end
        return parse_stream_lines(result.raw_body), nil
    end

    function client:build_image(tar_data: string, name: string, tag: string?)
        local image_tag = name .. ":" .. (tag or "latest")
        local query: {[string]: string} = { t = image_tag }
        local result, req_err = make_request(sock, "POST", "/build", {
            query = query,
            raw_body = tar_data,
            headers = { ["Content-Type"] = "application/x-tar" },
            timeout = "600s",
        })
        if req_err or not result then
            return nil, req_err
        end
        return parse_stream_lines(result.raw_body), nil
    end

    function client:tag_image(source: string, repo: string, tag: string)
        local query: {[string]: string} = { repo = repo, tag = tag }
        local _, req_err = make_request(sock, "POST", "/images/" .. source .. "/tag", {
            query = query,
        })
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    -- Networks

    function client:create_network(name: string, driver: string?)
        local body = {
            Name = name,
            Driver = driver or "bridge",
        }
        local result, req_err = make_request(sock, "POST", "/networks/create", { body = body })
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:remove_network(id: string)
        local _, req_err = make_request(sock, "DELETE", "/networks/" .. id)
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:list_networks(filters: table?)
        local query = {}
        if filters then
            query.filters = json.encode(filters)
        end
        local opts = {}
        if next(query) then
            opts.query = query
        end
        local result, req_err = make_request(sock, "GET", "/networks", opts)
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:inspect_network(id: string)
        local result, req_err = make_request(sock, "GET", "/networks/" .. id)
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:connect_network(net_id: string, container_id: string, aliases: {string}?)
        local endpoint_config = {}
        if aliases then
            endpoint_config.Aliases = aliases
        end
        local body = {
            Container = container_id,
        }
        if next(endpoint_config) then
            body.EndpointConfig = endpoint_config
        end
        local _, req_err = make_request(sock, "POST", "/networks/" .. net_id .. "/connect", { body = body })
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:disconnect_network(net_id: string, container_id: string)
        local body = { Container = container_id }
        local _, req_err = make_request(sock, "POST", "/networks/" .. net_id .. "/disconnect", { body = body })
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:prune_networks()
        local result, req_err = make_request(sock, "POST", "/networks/prune")
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    -- Volumes

    function client:create_volume(name: string, driver: string?, labels: {[string]: string}?)
        local body: {[string]: any} = {
            Name = name,
            Driver = driver or "local",
        }
        if labels then
            body.Labels = labels
        end
        local result, req_err = make_request(sock, "POST", "/volumes/create", { body = body })
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:inspect_volume(name: string)
        local result, req_err = make_request(sock, "GET", "/volumes/" .. name)
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:remove_volume(name: string, force: boolean?)
        local query = {}
        if force then
            query.force = "true"
        end
        local opts = {}
        if next(query) then
            opts.query = query
        end
        local _, req_err = make_request(sock, "DELETE", "/volumes/" .. name, opts)
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:list_volumes(filters: table?)
        local query = {}
        if filters then
            query.filters = json.encode(filters)
        end
        local opts = {}
        if next(query) then
            opts.query = query
        end
        local result, req_err = make_request(sock, "GET", "/volumes", opts)
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:prune_volumes()
        local result, req_err = make_request(sock, "POST", "/volumes/prune")
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    -- Container operations

    function client:restart_container(id: string, timeout: number?)
        local query = {}
        if timeout then
            query.t = timeout
        end
        local opts = {}
        if next(query) then
            opts.query = query
        end
        local _, req_err = make_request(sock, "POST", "/containers/" .. id .. "/restart", opts)
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:pause_container(id: string)
        local _, req_err = make_request(sock, "POST", "/containers/" .. id .. "/pause")
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:unpause_container(id: string)
        local _, req_err = make_request(sock, "POST", "/containers/" .. id .. "/unpause")
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:rename_container(id: string, new_name: string)
        local _, req_err = make_request(sock, "POST", "/containers/" .. id .. "/rename", {
            query = { name = new_name },
        })
        if req_err then
            return nil, req_err
        end
        return true, nil
    end

    function client:container_stats(id: string)
        local result, req_err = make_request(sock, "GET", "/containers/" .. id .. "/stats", {
            query = { stream = "false" },
            timeout = "15s",
        })
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:container_top(id: string, ps_args: string?)
        local query = {}
        if ps_args then
            query.ps_args = ps_args
        end
        local opts = {}
        if next(query) then
            opts.query = query
        end
        local result, req_err = make_request(sock, "GET", "/containers/" .. id .. "/top", opts)
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:prune_containers()
        local result, req_err = make_request(sock, "POST", "/containers/prune")
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:exec_container(id: string, command: string, options: {
        env: {string}?,
        work_dir: string?,
        user: string?,
        timeout: string?,
    }?): ({stdout: string, stderr: string, exit_code: number}?, string?)
        local opts = options or {}

        local cmd = { "sh", "-c", command }

        local exec_config: {[string]: any} = {
            AttachStdout = true,
            AttachStderr = true,
            Cmd = cmd,
        }
        if opts.env then exec_config.Env = opts.env end
        if opts.work_dir then exec_config.WorkingDir = opts.work_dir end
        if opts.user then exec_config.User = opts.user end

        local create_result, create_err = make_request(sock, "POST", "/containers/" .. id .. "/exec", {
            body = exec_config,
        })
        if create_err or not create_result then
            return nil, create_err or "exec create failed"
        end

        local exec_id = create_result.body and create_result.body.Id
        if not exec_id then
            return nil, "no exec ID returned"
        end

        local start_result, start_err = make_request(sock, "POST", "/exec/" .. exec_id .. "/start", {
            body = { Detach = false, Tty = false },
            timeout = opts.timeout or "300s",
        })
        if start_err or not start_result then
            return nil, start_err or "exec start failed"
        end

        local stdout_parts: {string} = {}
        local stderr_parts: {string} = {}
        if start_result.raw_body then
            local lines = parse_logs(tostring(start_result.raw_body))
            for _, entry in ipairs(lines) do
                if entry.stream == "stderr" then
                    table.insert(stderr_parts, entry.line)
                else
                    table.insert(stdout_parts, entry.line)
                end
            end
        end

        local inspect_result, inspect_err = make_request(sock, "GET", "/exec/" .. exec_id .. "/json")
        local exit_code = -1
        if not inspect_err and inspect_result and inspect_result.body then
            exit_code = tonumber(inspect_result.body.ExitCode) or -1
        end

        return {
            stdout = table.concat(stdout_parts, "\n"),
            stderr = table.concat(stderr_parts, "\n"),
            exit_code = exit_code,
        }, nil
    end

    -- Image operations

    function client:prune_images(dangling_only: boolean?)
        local filters = {}
        if dangling_only ~= false then
            filters.dangling = { "true" }
        end
        local query = {}
        if next(filters) then
            query.filters = json.encode(filters)
        end
        local opts = {}
        if next(query) then
            opts.query = query
        end
        local result, req_err = make_request(sock, "POST", "/images/prune", opts)
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    -- System operations

    function client:system_info()
        local result, req_err = make_request(sock, "GET", "/info")
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:system_version()
        local result, req_err = make_request(sock, "GET", "/version")
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    function client:system_df()
        local result, req_err = make_request(sock, "GET", "/system/df", {
            timeout = "60s",
        })
        if req_err or not result then
            return nil, req_err
        end
        return result.body, nil
    end

    client.parse_logs = parse_logs

    return client, nil
end

docker.parse_logs = parse_logs
docker.parse_stream_lines = parse_stream_lines
docker.parse_response = parse_response
docker.new_log_decoder = new_log_decoder
docker.new_log_cursor = new_log_cursor
docker.since_of = since_of

return docker
