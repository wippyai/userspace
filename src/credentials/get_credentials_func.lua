local ctx = require("ctx")
local credentials_repo = require("credentials_repo")
local component = require("component")

local VALIDATION_ERRORS = {
    MISSING_COMPONENT_ID = "Component ID is required in context",
    ACCESS_DENIED = "Insufficient access to credentials"
}

local function handle(request_dto)
    -- Get component_id from context
    local component_id, err = ctx.get("component_id")
    if err or not component_id or component_id == "" then
        return { error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    -- Validate READ access (minimum required for getting credentials)
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.READ)
    if not access_level then
        return { error = VALIDATION_ERRORS.ACCESS_DENIED .. ": " .. (access_err or "insufficient permissions") }
    end

    -- Get credentials from repository
    local creds, repo_err = credentials_repo.get_credentials(component_id)
    if repo_err then
        return { error = "Failed to get credentials: " .. repo_err }
    end

    if not creds then
        return { error = "No credentials found" }
    end

    -- Return repository structure directly (matches updated contract)
    return {
        component_id = creds.component_id,
        connection_name = creds.connection_name,
        connection_description = creds.connection_description,
        credentials = creds.credentials,
        metadata = creds.metadata,
        created_at = creds.created_at,
        updated_at = creds.updated_at
    }
end

return { handle = handle }