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

    -- Get component contract details
    local contract_info, err = provider_registry.get_component_contract(provider_id, oauth_provider)
    if not contract_info then
        return { success = false, error = err or "Provider not found" }
    end

    -- Success response - component contract information for registration
    return {
        component_contract_id = contract_info.component_contract_id,
        provider_id = contract_info.provider_id,
        oauth_provider = contract_info.oauth_provider,
        success = true
    }
end

return { handle = handle }
