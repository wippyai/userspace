local http = require("http")
local json = require("json")
local contract = require("contract")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Get provider name from URL
    local provider_name = req:param("provider_name")
    if not provider_name or provider_name == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Provider name is required"
        })
        return
    end

    -- Get discovery service
    local discovery_service, err = contract.get("userspace.oauth.discovery:provider_discovery")
    if not discovery_service then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Discovery service not available"
        })
        return
    end

    -- Open service instance
    local service, err = discovery_service:open()
    if not service then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to open discovery service"
        })
        return
    end

    -- Call discovery service
    local result, err = service:get_provider_info({
        oauth_provider = provider_name
    })

    if not result then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Service call failed"
        })
        return
    end

    -- Check for service errors
    if not result.success then
        res:set_status(http.STATUS.NOT_FOUND)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = result.error or ("Provider '" .. provider_name .. "' not found")
        })
        return
    end

    -- Return the service response directly (already clean, no contract details)
    -- Remove success field and add it at top level for API consistency
    local response = {
        success = true,
        id = result.id,
        name = result.name,
        title = result.title,
        description = result.description,
        oauth_provider = result.oauth_provider,
        classes = result.classes,
        namespace = result.namespace,
        default_scopes = result.default_scopes,
        available_scopes = result.available_scopes
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
    res:set_content_type(http.CONTENT.JSON)
    res:write_json(response)
end

return {
    handler = handler
}