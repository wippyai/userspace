local http = require("http")
local json = require("json")
local component = require("component")
local api_error = require("api_error")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    if req:method() ~= http.METHOD.DELETE then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Method not allowed. Use DELETE."
        })
        return
    end

    -- Get component ID and node ID from path parameters
    local component_id = req:param("component_id")
    local node_id = req:param("node_id")

    if not component_id or component_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing required path parameter: component_id"
        })
        return
    end

    if not node_id or node_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing required path parameter: node_id"
        })
        return
    end

    -- Open KB9 component (access validation happens here)
    local kb9_instance, kb9_err = component.open(component_id, component.ACCESS.WRITE, "userspace.kb9:kb9_contract")
    if not kb9_instance then
        local status_code = http.STATUS.INTERNAL_ERROR
        if kb9_err and kb9_err:find("not found") then
            status_code = http.STATUS.NOT_FOUND
        elseif kb9_err and (kb9_err:find("access denied") or kb9_err:find("Insufficient access")) then
            status_code = http.STATUS.FORBIDDEN
        end

        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, status_code, "Failed to open KB9 component", kb9_err)
        return
    end

    -- Execute DELETE_NODE command via the KB process
    local command_request = {
        commands = {
            {
                type = "DELETE_NODE",
                payload = {
                    id = node_id
                }
            }
        }
    }

    local result, exec_err = kb9_instance:execute_commands(command_request)

    if exec_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to execute delete command", exec_err)
        return
    end

    if not result.success then
        local status_code = http.STATUS.INTERNAL_ERROR

        -- Check for specific error types
        if result.error and result.error.code then
            if result.error.code == "NODE_NOT_FOUND" then
                status_code = http.STATUS.NOT_FOUND
            elseif result.error.code == "INVALID_NODE_ID" then
                status_code = http.STATUS.BAD_REQUEST
            end
        end

        res:set_status(status_code)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = result.error.message or "Delete command failed"
        })
        return
    end

    -- Return success response
    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        deleted_node_id = node_id,
        ops_executed = result.ops_executed or 0,
        message = "Node deleted successfully"
    })
end

return {
    handler = handler
}