local ctx = require("ctx")
local time = require("time")
local oauth_repo = require("oauth_repo")
local component = require("component")

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            description = "Error: No component context",
            updated_at = time.now():format(time.RFC3339)
        }
    end

    -- Validate access to component
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.READ)
    if not access_level then
        return {
            description = "Error: Access denied",
            updated_at = time.now():format(time.RFC3339)
        }
    end

    -- Get connection metadata (lightweight call)
    local metadata, err = oauth_repo.get_connection_metadata(component_id)
    if err then
        return {
            description = "Error: Failed to get connection status - " .. err,
            updated_at = time.now():format(time.RFC3339)
        }
    end

    -- Build status description
    local status_parts = {}

    -- Connection state
    table.insert(status_parts, "OAuth connection to " .. metadata.provider)
    table.insert(status_parts, "State: " .. metadata.connection_state)

    -- Token expiration status
    if metadata.expires_at then
        local current_time = time.now():unix()
        local is_expired = current_time >= metadata.expires_at

        if is_expired then
            table.insert(status_parts, "Token: EXPIRED")
        else
            local expires_in_hours = math.floor((metadata.expires_at - current_time) / 3600)
            if expires_in_hours > 24 then
                local expires_in_days = math.floor(expires_in_hours / 24)
                table.insert(status_parts, "Token: Valid for " .. expires_in_days .. " days")
            elseif expires_in_hours > 0 then
                table.insert(status_parts, "Token: Valid for " .. expires_in_hours .. " hours")
            else
                local expires_in_minutes = math.floor((metadata.expires_at - current_time) / 60)
                table.insert(status_parts, "Token: Valid for " .. expires_in_minutes .. " minutes")
            end
        end
    else
        table.insert(status_parts, "Token: No expiration")
    end

    -- Scopes
    if metadata.scopes_granted and metadata.scopes_granted ~= "" then
        local scope_count = 0
        for _ in metadata.scopes_granted:gmatch("%S+") do
            scope_count = scope_count + 1
        end
        table.insert(status_parts, "Scopes: " .. scope_count .. " granted")
    end

    local description = table.concat(status_parts, " | ")

    return {
        description = description,
        updated_at = time.now():format(time.RFC3339)
    }
end

return { handle = handle }