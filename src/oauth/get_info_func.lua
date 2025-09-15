local ctx = require("ctx")
local oauth_repo = require("oauth_repo")
local component = require("component")

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            error = "No component context: " .. err
        }
    end

    -- Validate access to component
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.READ)
    if not access_level then
        return {
            error = "Access denied: " .. (access_err or "insufficient permissions")
        }
    end

    -- Get complete connection data from repository
    local connection, err = oauth_repo.get_connection(component_id)
    if err then
        return {
            error = "Failed to get connection info: " .. err
        }
    end

    -- Return connection information (excluding sensitive data)
    return {
        provider = connection.provider,
        connection_name = connection.connection_name,
        connection_description = connection.connection_description or "",
        scopes_granted = connection.scopes_granted or "",
        connection_state = connection.connection_state,
        created_at = connection.created_at,
        last_token_refresh = connection.last_token_refresh,
        user_profile = {
            provider_user_id = connection.user_profile.provider_user_id or "",
            email = connection.user_profile.email or "",
            display_name = connection.user_profile.display_name or "",
            username = connection.user_profile.username or "",
            avatar_url = connection.user_profile.avatar_url or ""
        }
    }
end

return { handle = handle }