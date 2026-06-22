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

    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({ success = false, error = "Missing required path parameter: component_id" })
        return
    end

    local service, err = component.get_service()
    if err or not service then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get component service", err)
        return
    end

    local result, call_err = service:delete_component({ component_id = component_id })
    if not result then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Service call failed", call_err)
        return
    end

    if not result.success then
        local status_code = http.STATUS.BAD_REQUEST
        if result.error then
            if result.error:find("not found") or result.error:find("Component not found") then
                status_code = http.STATUS.NOT_FOUND
            elseif result.error:find("access denied") or result.error:find("Insufficient access") then
                status_code = http.STATUS.FORBIDDEN
            end
        end

        res:set_status(status_code)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({ success = false, error = result.error or "Service returned error" })
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        message = "Component deleted successfully",
        component_id = component_id,
        deleted = result.deleted
    })
end

return { handler = handler }
