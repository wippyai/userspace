local ctx = require("ctx")
local time = require("time")
local oauth_repo = require("oauth_repo")
local component = require("component")

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            success = false,
            error = "No component context: " .. err
        }
    end

    -- Validate access to component
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.READ)
    if not access_level then
        return {
            success = false,
            error = "Access denied: " .. (access_err or "insufficient permissions")
        }
    end

    -- Get token data from repository
    local token_data, err = oauth_repo.get_access_token(component_id)
    if err then
        return {
            success = false,
            error = "Failed to get access token: " .. err
        }
    end

    local current_time = time.now():unix()
    local is_expired = false

    -- Check if token is expired
    if token_data.expires_at then
        is_expired = current_time >= token_data.expires_at
    end

    -- Return token information
    return {
        success = true,
        access_token = token_data.access_token,
        token_type = "Bearer",
        expires_at = token_data.expires_at,
        is_expired = is_expired
    }
end

return { handle = handle }