local http = require("http")
local json = require("json")
local time = require("time")
local component = require("component")
local api_error = require("api_error")

local STATUS = http.STATUS
local CONTENT = http.CONTENT

local function handler()
    local req = http.request()
    local res = http.response()

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    res:set_content_type(CONTENT.JSON)

    if req:method() ~= "PUT" then
        res:set_status(STATUS.METHOD_NOT_ALLOWED)
        res:write_json({ success = false, error = "Method not allowed. Use PUT." })
        return
    end

    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({ success = false, error = "Component ID is required in URL path" })
        return
    end

    local body, parse_err = req:body_json()
    if parse_err then
        api_error.fail(res, STATUS.BAD_REQUEST, "Invalid JSON request body", parse_err)
        return
    end

    if not body.title and not body.description and not body.metadata then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "At least one field to update is required (title, description, or metadata)"
        })
        return
    end

    local access_level, access_err = component.validate_access(component_id, component.ACCESS.WRITE)
    if not access_level or access_level == 0 then
        api_error.fail(res, STATUS.FORBIDDEN, "Insufficient permissions to update this component", access_err)
        return
    end

    local service, err = component.get_service()
    if err or not service then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to get component service", err)
        return
    end

    local update_commands = {}

    if body.title then
        table.insert(update_commands, {
            type = "PUT_META",
            payload = { key = "title", value = body.title }
        })
    end

    if body.description then
        table.insert(update_commands, {
            type = "PUT_META",
            payload = { key = "description", value = body.description }
        })
    end

    if body.metadata and type(body.metadata) == "table" then
        for key, value in pairs(body.metadata) do
            table.insert(update_commands, {
                type = "PUT_META",
                payload = { key = key, value = value }
            })
        end
    end

    local update_result, update_err = service:update_component({
        component_id = component_id,
        commands = update_commands
    })

    if update_err then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to update component", update_err)
        return
    end

    if not update_result or not update_result.success then
        local error_msg = (update_result and update_result.error) or "Component update failed"

        local status_code = STATUS.INTERNAL_ERROR
        if error_msg:find("not found") or error_msg:find("Component not found") then
            status_code = STATUS.NOT_FOUND
        elseif error_msg:find("access denied") or error_msg:find("Insufficient access") then
            status_code = STATUS.FORBIDDEN
        end

        res:set_status(status_code)
        res:write_json({ success = false, error = error_msg })
        return
    end

    res:set_status(STATUS.OK)
    res:write_json({
        success = true,
        component_id = component_id,
        title = body.title,
        description = body.description,
        updated_fields = {
            title = body.title and true or false,
            description = body.description and true or false,
            metadata = body.metadata and true or false
        },
        updated_at = update_result.updated_at or time.now():format(time.RFC3339)
    })
end

return { handler = handler }
