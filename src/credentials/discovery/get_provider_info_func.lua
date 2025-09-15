local provider_registry = require("provider_registry")

local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_IDENTIFIER = "Either provider_id or credential_provider is required"
}

local function handle(request_dto)
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    local provider_id = request_dto.provider_id
    local credential_provider = request_dto.credential_provider

    if (not provider_id or provider_id == "") and (not credential_provider or credential_provider == "") then
        return { success = false, error = VALIDATION_ERRORS.MISSING_IDENTIFIER }
    end

    local provider_info, err = provider_registry.get_provider_info(provider_id, credential_provider)
    if not provider_info then
        return { success = false, error = err or "Provider not found" }
    end

    local result = {
        id = provider_info.id,
        name = provider_info.name,
        title = provider_info.title,
        description = provider_info.description,
        credential_provider = provider_info.credential_provider,
        group = provider_info.group,
        classes = provider_info.classes,
        tags = provider_info.tags,
        namespace = provider_info.namespace,
        credential_schema = provider_info.credential_schema,
        ui_config = provider_info.ui_config,
        success = true
    }

    if provider_info.icon then
        result.icon = provider_info.icon
    end

    if provider_info.create_ui_id then
        result.create_ui_id = provider_info.create_ui_id
    end

    if provider_info.manage_ui_id then
        result.manage_ui_id = provider_info.manage_ui_id
    end

    if provider_info.validation_contract_id then
        result.validation_contract_id = provider_info.validation_contract_id
    end

    return result
end

return { handle = handle }