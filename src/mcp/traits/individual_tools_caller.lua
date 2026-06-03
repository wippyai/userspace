local mcp_client = require("mcp_client")
local json = require("json")
local time = require("time")
local ctx = require("ctx")

local function individual_tools_handler(params)
    local server_id = ctx.get("server_id")
    if not server_id then
        return nil, "No server_id configured in context"
    end

    if not params.tool_name then
        return nil, "tool_name is required"
    end

    -- Get tool schemas from context for validation
    local tool_schemas = ctx.get("tool_schemas") or {}
    local tool_schema = tool_schemas[params.tool_name]

    -- If we have a real schema for this tool, we could validate parameters here
    -- For now, just pass through to MCP server for validation

    local client, err = mcp_client.connect(server_id :: string)
    if err then
        return nil, "Failed to connect to MCP server '" .. server_id .. "': " .. err
    end

    local tool_result, tool_err = mcp_client.call_tool(client, params.tool_name, params.parameters or {})
    mcp_client.close(client)

    if tool_err then
        return nil, "Tool call failed: " .. tool_err
    end

    return tool_result
end

return { individual_tools_handler = individual_tools_handler }
