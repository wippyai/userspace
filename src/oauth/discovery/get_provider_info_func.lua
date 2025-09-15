local provider_registry = require("provider_registry")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_IDENTIFIER = "Either provider_id or oauth_provider is required"
}

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    -- Validate that at least one identifier is provided
    local provider_id = request_dto.provider_id
    local oauth_provider = request_dto.oauth_provider

    if (not provider_id or provider_id == "") and (not oauth_provider or oauth_provider == "") then
        return { success = false, error = VALIDATION_ERRORS.MISSING_IDENTIFIER }
    end

    -- Get provider information (no contract details, just public info and scopes)
    local provider_info, err = provider_registry.get_provider_info(provider_id, oauth_provider)
    if not provider_info then
        return { success = false, error = err or "Provider not found" }
    end

    -- Success response - only public information, no contract implementation details
    local result = {
        id = provider_info.id,
        name = provider_info.name,
        title = provider_info.title,
        description = provider_info.description,
        oauth_provider = provider_info.oauth_provider,
        classes = provider_info.classes,
        namespace = provider_info.namespace,
        default_scopes = provider_info.default_scopes,
        available_scopes = provider_info.available_scopes,
        success = true
    }

    -- Add optional fields if present
    if provider_info.icon then
        result.icon = provider_info.icon
    end

    if provider_info.create_ui_id then
        result.create_ui_id = provider_info.create_ui_id
    end

    if provider_info.manage_ui_id then
        result.manage_ui_id = provider_info.manage_ui_id
    end

    return result
end

return { handle = handle }