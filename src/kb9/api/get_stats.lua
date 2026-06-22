local http = require("http")
local json = require("json")
local component = require("component")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    if req:method() ~= http.METHOD.GET then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Method not allowed. Use GET."
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

    -- Parse query parameters
    local include_content_size = req:query("include_content_size") == "true" -- default false

    -- Open KB9 component (access validation happens here)
    local kb9_instance, kb9_err = component.open(component_id, component.ACCESS.READ, "userspace.kb9:kb9_contract")
    if not kb9_instance then
        local status_code = http.STATUS.INTERNAL_ERROR
        if kb9_err and kb9_err:find("not found") then
            status_code = http.STATUS.NOT_FOUND
        elseif kb9_err and (kb9_err:find("access denied") or kb9_err:find("Insufficient access")) then
            status_code = http.STATUS.FORBIDDEN
        end

        res:set_status(status_code)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = kb9_err or "Failed to open KB9 component"
        })
        return
    end

    -- Prepare stats request
    local stats_request = {
        include_content_size = include_content_size
    }

    -- Execute get_stats
    local result, stats_err = kb9_instance:get_stats(stats_request)
    if stats_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to get KB9 stats: " .. stats_err
        })
        return
    end

    -- Check if it's an actual error vs empty results
    if not result.success and result.error then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json(result)
        return
    end

    -- Return success response
    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json(result)
end

return {
    handler = handler
}