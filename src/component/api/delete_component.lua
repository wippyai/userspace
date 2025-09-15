local http = require("http")
local json = require("json")
local component = require("component")

local function handler()
    -- Get response and request objects
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
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

    -- Use component.get_service() shortcut instead of manual contract getting
    local service, err = component.get_service()
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to get component service: " .. err
        })
        return
    end

    -- Build request DTO
    local request_dto = {
        component_id = component_id
    }

    -- Call the service
    local result, err = service:delete_component(request_dto)
    if not result then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Service call failed: " .. (err or "unknown error")
        })
        return
    end

    -- Check if service returned an error
    if not result.success then
        -- Map common errors to appropriate HTTP status codes
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
        res:write_json({
            success = false,
            error = result.error or "Service returned error"
        })
        return
    end

    -- Return successful response
    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        message = "Component deleted successfully",
        component_id = component_id,
        deleted = result.deleted
    })
end

return {
    handler = handler
}
