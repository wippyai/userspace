local ctx = require("ctx")
local credentials_repo = require("credentials_repo")
local component = require("component")

local VALIDATION_ERRORS = {
    MISSING_COMPONENT_ID = "Component ID is required in context",
    ACCESS_DENIED = "Insufficient access to credentials status"
}

local function handle(request_dto)
    -- Get component_id from context
    local component_id, err = ctx.get("component_id")
    if err or not component_id or component_id == "" then
        return { error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    -- Validate READ access for status
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.READ)
    if not access_level then
        return { error = VALIDATION_ERRORS.ACCESS_DENIED .. ": " .. (access_err or "insufficient permissions") }
    end

    -- Try to get connection metadata to determine status
    local metadata, repo_err = credentials_repo.get_connection_metadata(component_id)

    local description
    local updated_at = nil

    if metadata then
        -- Credentials exist - provide status
        local provider = metadata.metadata and metadata.metadata.provider or "unknown"
        local connection_name = metadata.connection_name or "credentials"

        description = string.format("Connection '%s' configured for %s provider",
                                   connection_name, provider)
        updated_at = metadata.updated_at
    else
        -- No credentials stored
        description = "No credentials configured"
    end

    -- Success response
    return {
        description = description,
        updated_at = updated_at
    }
end

return { handle = handle }