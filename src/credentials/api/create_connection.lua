local http = require("http")
local json = require("json")
local contract = require("contract")
local uuid = require("uuid")
local component = require("component")
local credentials_repo = require("credentials_repo")
local api_error = require("api_error")

local log = require("logger"):named("userspace.credentials.api")

local STATUS = http.STATUS
local CONTENT = http.CONTENT
local DISCOVERY_SERVICE_CONTRACT = "userspace.credentials.discovery:provider_discovery"
local CREDENTIAL_VALIDATOR_CONTRACT = "userspace.credentials:credential_validator"

local function call_provider_validator(provider_info, form_credentials)
    if not provider_info.validation_contract_id then
        return form_credentials, nil
    end

    local validator_contract, err = contract.get(CREDENTIAL_VALIDATOR_CONTRACT)
    if err then
        log:error("Failed to get credential validator contract", { error = tostring(err) })
        return nil, {
            field = "connection",
            error = "Failed to get credential validator contract"
        }
    end

    local validator_instance, err = validator_contract:open(provider_info.validation_contract_id)
    if err then
        log:error("Failed to initialize credential validator", { error = tostring(err) })
        return nil, {
            field = "connection",
            error = "Failed to initialize credential validator"
        }
    end

    local result, err = validator_instance:normalize_and_validate(form_credentials)
    if err then
        log:error("Validator error", { error = tostring(err) })
        return nil, {
            field = "connection",
            error = "Validator error"
        }
    end

    if not result.success then
        return nil, {
            field = result.field or "unknown",
            error = result.error or "Validation failed"
        }
    end

    return result.normalized_credentials, nil
end

local function handler()
    local req = http.request()
    local res = http.response()

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    res:set_content_type(CONTENT.JSON)

    if req:method() ~= "POST" then
        res:set_status(STATUS.METHOD_NOT_ALLOWED)
        res:write_json({
            success = false,
            error = "Method not allowed. Use POST."
        })
        return
    end

    local provider_name = req:param("provider_name")
    if not provider_name or provider_name == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Provider name is required in URL path"
        })
        return
    end

    local body, parse_err = req:body_json()
    if parse_err then
        api_error.fail(res, STATUS.BAD_REQUEST, "Invalid JSON request body", parse_err)
        return
    end

    if not body.connection_name or body.connection_name == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Connection name is required"
        })
        return
    end

    if not body.credentials or type(body.credentials) ~= "table" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Credentials object is required"
        })
        return
    end

    local discovery_service, err = contract.get(DISCOVERY_SERVICE_CONTRACT)
    if err then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Discovery service not available", err)
        return
    end

    local discovery_instance, err = discovery_service:open()
    if err then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to open discovery service", err)
        return
    end

    local provider_info, err = discovery_instance:get_provider_info({
        credential_provider = provider_name
    })

    if err then
        api_error.fail(res, STATUS.NOT_FOUND, "Provider not found", err)
        return
    end

    local normalized_credentials, validation_error = call_provider_validator(provider_info, body.credentials)
    if validation_error then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = validation_error.error,
            field = validation_error.field
        })
        return
    end

    local component_contract_info, err = discovery_instance:get_component_contract({
        credential_provider = provider_name
    })

    if err then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to get component contract", err)
        return
    end

    local component_id = uuid.v4()

    local connection_data = {
        connection_name = body.connection_name,
        connection_description = body.connection_description or "",
        credentials = normalized_credentials,
        metadata = {
            provider = provider_name,
            created_via = "api"
        }
    }

    if body.metadata and type(body.metadata) == "table" then
        for key, value in pairs(body.metadata) do
            connection_data.metadata[key] = value
        end
    end

    local store_result, store_err = credentials_repo.store_credentials(component_id, connection_data)
    if store_err then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to store credentials", store_err)
        return
    end

    -- Use component.get_service() shortcut instead of manual contract getting
    local service, err = component.get_service()
    if err then
        credentials_repo.delete_credentials(component_id)
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to get component service", err)
        return
    end

    local meta = {
        class = "connection",
        credential_connection = true,
        provider = provider_name,
        display_id = component_contract_info.provider_id,
        type = "Credential Connection",
        title = body.connection_name,
        description = body.connection_description or ("Credential connection to " .. provider_name)
    }

    local register_request = {
        component_id = component_id,
        impl_id = component_contract_info.component_contract_id,
        meta = meta,
        private_context = { component_id = component_id }
    }

    local result, err = service:register_component(register_request)
    if err then
        credentials_repo.delete_credentials(component_id)
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to register component", err)
        return
    end

    if not result or not result.success then
        credentials_repo.delete_credentials(component_id)
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to register component", result and result.error)
        return
    end

    res:set_status(STATUS.CREATED)
    res:write_json({
        success = true,
        component_id = component_id,
        connection_name = body.connection_name,
        provider = {
            name = provider_info.name,
            title = provider_info.title
        },
        created_at = store_result.created_at
    })
end

return {
    handler = handler
}
