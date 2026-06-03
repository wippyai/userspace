local json = require("json")
local time = require("time")
local logger = require("logger")
local uuid = require("uuid")
local security = require("security")
local mcp_consts = require("mcp_consts")

local mcp_client = {}

local function verify_access(name)
    local resource = "mcp.client." .. name
    local allowed = security.can("mcp.connect", resource)
    if not allowed then
        return nil, "Access denied to MCP service: " .. name
    end
    return true
end

local function create_client(name)
    if not name then
        return nil, "Name is required"
    end

    local access_ok, access_err = verify_access(name)
    if not access_ok then
        return nil, access_err
    end

    local client = {
        name = name,
        service_name = mcp_consts.REGISTRY.PREFIX .. name,
        connected = false,
        tools = {},
        log = logger:named("mcp.client." .. name)
    }

    return client
end

local function send_and_wait(client, request_data, timeout_ms)
    timeout_ms = timeout_ms or mcp_consts.DEFAULTS.RESPONSE_TIMEOUT_MS

    local request_id, uuid_err = uuid.v4()
    if uuid_err then
        return nil, "Failed to generate request ID: " .. uuid_err
    end

    request_data.id = request_id
    request_data.reply_to_topic = mcp_consts.TOPICS.RESPONSE .. "." .. request_id

    local reply_channel = process.listen(request_data.reply_to_topic)

    client.log:debug("Sending request", {
        request_id = request_id,
        type = request_data.type,
        service_name = client.service_name,
        reply_to_topic = request_data.reply_to_topic
    })

    local send_ok = process.send(client.service_name :: string, mcp_consts.TOPICS.REQUEST, request_data)
    if not send_ok then
        client.log:error("Failed to send request", {
            service_name = client.service_name,
            request_id = request_id
        })
        return nil, "Failed to send request to MCP service: " .. client.service_name
    end

    local timeout_channel = time.after(tostring(timeout_ms) .. "ms")

    local result = channel.select({
        reply_channel:case_receive(),
        timeout_channel:case_receive()
    })

    if result.channel == timeout_channel then
        client.log:error("Request timeout", {
            request_id = request_id,
            timeout_ms = timeout_ms
        })
        return nil, "Request timeout"
    end

    local response = result.value
    client.log:debug("Received response", {
        response = response,
        request_id = request_id
    })

    return response
end

function mcp_client.connect(name)
    return create_client(name)
end

function mcp_client.ping(client)
    if not client then
        return nil, "Client is required"
    end

    client.log:debug("Pinging MCP service")

    local request = {
        type = "ping"
    }

    local response, err = send_and_wait(client, request)
    if err then
        return nil, err
    end

    if response.error then
        return nil, response.error
    end

    return response.success and response.pong
end

function mcp_client.get_tools(client)
    if not client then
        return nil, "Client is required"
    end

    client.log:debug("Getting tools from MCP service")

    local request = {
        type = "tools_list"
    }

    local response, err = send_and_wait(client, request)
    if err then
        return nil, err
    end

    if response.error then
        return nil, response.error
    end

    client.tools = response.tools or {}
    client.log:info("Tools loaded", { count = #client.tools })

    return client.tools
end

function mcp_client.call_tool(client, tool_name, params)
    if not client then
        return nil, "Client is required"
    end

    if not tool_name then
        return nil, "Tool name is required"
    end

    client.log:debug("Calling tool", { tool = tool_name, params = params })

    local request = {
        type = "tool_call",
        tool_name = tool_name,
        params = params or {}
    }

    local response, err = send_and_wait(client, request, mcp_consts.DEFAULTS.TOOL_CALL_TIMEOUT_MS)
    if err then
        return nil, err
    end

    if response.error then
        return nil, response.error
    end

    client.log:info("Tool call completed", { tool = tool_name, success = true })

    return response.result
end

function mcp_client.get_status(client)
    if not client then
        return {
            name = "unknown",
            connected = false,
            tools_count = 0
        }
    end

    return {
        name = client.name,
        service_name = client.service_name,
        connected = client.connected,
        tools_count = #client.tools
    }
end

function mcp_client.close(client)
    if not client then
        return true
    end

    client.log:debug("Closing MCP client connection")
    client.connected = false
    client.tools = {}

    return true
end

return mcp_client