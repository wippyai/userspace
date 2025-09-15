local ctx = require("ctx")
local credentials_repo = require("credentials_repo")
local component = require("component")

local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_COMPONENT_ID = "Component ID is required in context",
    MISSING_CONNECTION_NAME = "connection_name is required",
    MISSING_CREDENTIALS = "credentials is required and must be a table",
    INVALID_METADATA = "metadata must be a table if provided",
    ACCESS_DENIED = "Insufficient access to store credentials"
}

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.connection_name or request_dto.connection_name == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_CONNECTION_NAME }
    end

    if not request_dto.credentials or type(request_dto.credentials) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_CREDENTIALS }
    end

    local metadata = request_dto.metadata
    if metadata and type(metadata) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_METADATA }
    end

    -- Get component_id from context
    local component_id, err = ctx.get("component_id")
    if err or not component_id or component_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    -- Validate WRITE access (required for storing credentials)
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.WRITE)
    if not access_level then
        return { success = false, error = VALIDATION_ERRORS.ACCESS_DENIED .. ": " .. (access_err or "insufficient permissions") }
    end

    -- Build connection_data for repository
    local connection_data = {
        connection_name = request_dto.connection_name,
        connection_description = request_dto.connection_description,
        credentials = request_dto.credentials,
        metadata = metadata or {}
    }

    -- Store credentials using repository
    local result, repo_err = credentials_repo.store_credentials(component_id, connection_data)

    if repo_err then
        return { success = false, error = repo_err }
    end

    -- Success response
    return {
        success = true,
        component_id = result.component_id,
        created_at = result.created_at,
        updated_at = result.updated_at
    }
end

return { handle = handle }