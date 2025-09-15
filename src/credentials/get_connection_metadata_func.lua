local ctx = require("ctx")
local credentials_repo = require("credentials_repo")
local component = require("component")

local VALIDATION_ERRORS = {
    MISSING_COMPONENT_ID = "Component ID is required in context",
    ACCESS_DENIED = "Insufficient access to connection metadata"
}

local function handle(request_dto)
    -- Get component_id from context
    local component_id, err = ctx.get("component_id")
    if err or not component_id or component_id == "" then
        return { error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    -- Validate READ access (minimum required for metadata)
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.READ)
    if not access_level then
        return { error = VALIDATION_ERRORS.ACCESS_DENIED .. ": " .. (access_err or "insufficient permissions") }
    end

    -- Get connection metadata from repository (no decryption)
    local metadata, repo_err = credentials_repo.get_connection_metadata(component_id)
    if repo_err then
        return { error = "Failed to get connection metadata: " .. repo_err }
    end

    if not metadata then
        return { error = "No connection found" }
    end

    -- Return repository structure directly
    return {
        component_id = metadata.component_id,
        connection_name = metadata.connection_name,
        connection_description = metadata.connection_description,
        metadata = metadata.metadata,
        created_at = metadata.created_at,
        updated_at = metadata.updated_at
    }
end

return { handle = handle }