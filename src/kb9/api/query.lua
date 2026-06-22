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

    if req:method() ~= http.METHOD.POST then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Method not allowed. Use POST."
        })
        return
    end

    -- Get component ID from path parameter
    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing required path parameter: component_id"
        })
        return
    end

    -- Parse request body
    local body_str = req:body()
    if not body_str or body_str == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Request body is required"
        })
        return
    end

    local request_data, decode_err = json.decode(body_str)
    if decode_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.BAD_REQUEST, "Invalid JSON in request body", decode_err)
        return
    end

    -- Validate required fields
    if not request_data.query or request_data.query == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Query is required"
        })
        return
    end

    -- Open KB9 component with queryable contract (access validation happens here)
    local kb9_instance, kb9_err = component.open(component_id, component.ACCESS.READ, "userspace.knowledge:queryable")
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

    -- Prepare query request
    local query_request = {
        query = request_data.query,
        limit = request_data.limit or 10,
        options = request_data.options or {}
    }

    -- Execute query
    local result, query_err = kb9_instance:query(query_request)
    if query_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to query KB9", query_err)
        return
    end

    -- Check if it's an actual error vs empty results
    if not result.success and result.error then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json(result)
        return
    end

    -- Return success response (even if no results found)
    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        items = result.items or {},
        count = result.count or 0
    })
end

return {
    handler = handler
}