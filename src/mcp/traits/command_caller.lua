local mcp_client = require("mcp_client")
local json = require("json")
local time = require("time")
local ctx = require("ctx")

local function command_caller_handler(params)
    local server_id = ctx.get("server_id")
    local tool_name = ctx.get("tool_name")

    if not server_id then
        return nil, "No server_id configured in context"
    end

    if not tool_name then
        return nil, "No tool_name configured in context"
    end

    local client, err = mcp_client.connect(server_id :: string)
    if err then
        return nil, "Failed to connect to MCP server '" .. server_id .. "': " .. err
    end

    local tool_result, tool_err = mcp_client.call_tool(client, tool_name, params.parameters or {})
    mcp_client.close(client)

    if tool_err then
        return nil, "Tool call failed: " .. tool_err
    end

    return tool_result
end

return { command_caller_handler = command_caller_handler }
