local ctx = require("ctx")
local credentials_repo = require("credentials_repo")
local component = require("component")

local VALIDATION_ERRORS = {
    MISSING_COMPONENT_ID = "Component ID is required in context",
    ACCESS_DENIED = "Insufficient access to credentials info"
}

local function handle(request_dto)
    -- Get component_id from context
    local component_id, err = ctx.get("component_id")
    if err or not component_id or component_id == "" then
        return { error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    -- Validate READ access (minimum required for info)
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.READ)
    if not access_level then
        return { error = VALIDATION_ERRORS.ACCESS_DENIED .. ": " .. (access_err or "insufficient permissions") }
    end

    -- Try to get connection metadata to check if credentials exist
    local metadata, repo_err = credentials_repo.get_connection_metadata(component_id)

    -- Build response based on whether credentials exist
    if metadata then
        -- Credentials exist
        return {
            component_id = component_id,
            has_credentials = true,
            connection_name = metadata.connection_name,
            metadata = metadata.metadata,
            created_at = metadata.created_at,
            updated_at = metadata.updated_at
        }
    else
        -- No credentials found
        return {
            component_id = component_id,
            has_credentials = false
        }
    end
end

return { handle = handle }