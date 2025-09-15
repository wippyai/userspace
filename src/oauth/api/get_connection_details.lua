local http = require("http")
local json = require("json")
local contract = require("contract")
local component = require("component")
local oauth_repo = require("oauth_repo")

-- Constants
local DISCOVERY_SERVICE_CONTRACT = "userspace.oauth.discovery:provider_discovery"

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Set JSON content type
    res:set_content_type(http.CONTENT.JSON)

    -- Get component ID from URL params
    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Component ID is required"
        })
        return
    end

    -- Validate component access (READ permission required = 1)
    local access_level, access_err = component.validate_access(component_id, 1)
    if not access_level or access_level == 0 then
        res:set_status(http.STATUS.FORBIDDEN)
        res:write_json({
            success = false,
            error = access_err or "Insufficient permissions to view this connection"
        })
        return
    end

    -- Get OAuth connection details
    local connection, err = oauth_repo.get_connection(component_id)
    if err then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "OAuth connection not found: " .. err
        })
        return
    end

    -- Get provider discovery service to get provider information
    local discovery_service, err = contract.get(DISCOVERY_SERVICE_CONTRACT)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Discovery service not available: " .. err
        })
        return
    end

    -- Open discovery service
    local discovery_instance, err = discovery_service:open()
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to open discovery service: " .. err
        })
        return
    end

    -- Get provider information
    local provider_info, err = discovery_instance:get_provider_info({
        oauth_provider = connection.provider
    })

    if err then
        -- Provider info not found, but continue with limited information
        provider_info = {
            name = connection.provider,
            title = connection.provider,
            description = "OAuth provider",
            available_scopes = {},
            default_scopes = {}
        }
    end

    -- Prepare response with combined information
    local response = {
        success = true,
        connection = {
            -- OAuth connection data
            component_id = connection.component_id,
            provider = connection.provider,
            connection_name = connection.connection_name,
            connection_description = connection.connection_description,
            connection_state = connection.connection_state,
            token_type = connection.token_type,
            expires_at = connection.expires_at,
            refresh_expires_at = connection.refresh_expires_at,
            created_at = connection.created_at,
            updated_at = connection.updated_at,
            last_token_refresh = connection.last_token_refresh,

            -- Granted scopes (from OAuth data)
            scopes_granted = connection.scopes_granted,

            -- User profile information (if available)
            user_profile = connection.user_profile or {},
            user_display_name = (connection.user_profile and connection.user_profile.name) or
                               (connection.user_profile and connection.user_profile.display_name) or nil,
            user_email = (connection.user_profile and connection.user_profile.email) or nil,

            -- Provider information for display
            provider_title = provider_info.title,
            provider_icon = provider_info.icon,
            provider_description = provider_info.description
        },
        provider = {
            -- Provider metadata
            id = provider_info.id,
            name = provider_info.name,
            title = provider_info.title,
            description = provider_info.description,
            icon = provider_info.icon,
            oauth_provider = provider_info.oauth_provider,

            -- Available scopes for this provider
            available_scopes = provider_info.available_scopes or {},
            default_scopes = provider_info.default_scopes or {}
        }
    }

    res:set_status(http.STATUS.OK)
    res:write_json(response)
end

return {
    handler = handler
}