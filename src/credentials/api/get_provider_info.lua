local http = require("http")
local json = require("json")
local contract = require("contract")
local api_error = require("api_error")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Set JSON content type
    res:set_content_type(http.CONTENT.JSON)

    -- Only allow GET requests
    if req:method() ~= "GET" then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:write_json({
            success = false,
            error = "Method not allowed. Use GET."
        })
        return
    end

    -- Get provider name from URL
    local provider_name = req:param("provider_name")
    if not provider_name or provider_name == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Provider name is required"
        })
        return
    end

    -- Get discovery service
    local discovery_service, err = contract.get("userspace.credentials.discovery:provider_discovery")
    if not discovery_service then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Discovery service not available", err)
        return
    end

    -- Open service instance
    local service, err = discovery_service:open()
    if not service then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to open discovery service", err)
        return
    end

    -- Call discovery service
    local result, err = service:get_provider_info({
        credential_provider = provider_name
    })

    if not result then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Service call failed", err)
        return
    end

    -- Check for service errors
    if not result.success then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = result.error or ("Provider '" .. provider_name .. "' not found")
        })
        return
    end

    -- Return the service response with all schema and UI config
    local response = {
        success = true,
        id = result.id,
        name = result.name,
        title = result.title,
        description = result.description,
        credential_provider = result.credential_provider,
        group = result.group,
        classes = result.classes,
        tags = result.tags,
        namespace = result.namespace,
        credential_schema = result.credential_schema,
        ui_config = result.ui_config
    }

    -- Add optional fields if present
    if result.icon then
        response.icon = result.icon
    end

    if result.create_ui_id then
        response.create_ui_id = result.create_ui_id
    end

    if result.manage_ui_id then
        response.manage_ui_id = result.manage_ui_id
    end

    res:set_status(http.STATUS.OK)
    res:write_json(response)
end

return {
    handler = handler
}