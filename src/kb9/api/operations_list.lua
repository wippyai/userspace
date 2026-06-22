local http = require("http")
local component = require("component")
local reader = require("userspace_reader")
local api_error = require("api_error")

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

    local kb9_instance, kb9_err = component.open(component_id, component.ACCESS.READ, "userspace.kb9:kb9_contract")
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

    local limit = tonumber(req:query("limit")) or 50
    local offset = tonumber(req:query("offset")) or 0
    local status_filter = req:query("status")

    if limit < 1 then limit = 1 end
    if limit > 100 then limit = 100 end

    local ops_reader = reader.for_operations(component_id)
    if status_filter then
        ops_reader = ops_reader:with_status(status_filter)
    end

    local operations, list_err = ops_reader:limit(limit):offset(offset):all()

    if list_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to list operations", list_err)
        return
    end

    local total, count_err = ops_reader:count()

    if count_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to count operations", count_err)
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        operations = operations,
        total = total,
        limit = limit,
        offset = offset
    })
end

return {
    handler = handler
}
