local http = require("http")
local json = require("json")
local contract = require("contract")
local component = require("component")

local STATUS = http.STATUS
local CONTENT = http.CONTENT
local DISCOVERY_SERVICE_CONTRACT = "userspace.credentials.discovery:provider_discovery"
local CREDENTIAL_VALIDATOR_CONTRACT = "userspace.credentials:credential_validator"
local CREDENTIALS_CONTRACT = "userspace.credentials:credentials_contract"

local function call_provider_validator(provider_info, form_credentials)
    if not provider_info.validation_contract_id then
        return form_credentials, nil
    end

    local validator_contract, err = contract.get(CREDENTIAL_VALIDATOR_CONTRACT)
    if err then
        return nil, {
            field = "connection",
            error = "Failed to get credential validator contract: " .. err
        }
    end

    local validator_instance, err = validator_contract:open(provider_info.validation_contract_id)
    if err then
        return nil, {
            field = "connection",
            error = "Failed to initialize credential validator: " .. err
        }
    end

    local result, err = validator_instance:normalize_and_validate(form_credentials)
    if err then
        return nil, {
            field = "connection",
            error = "Validator error: " .. err
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

    if req:method() ~= "PUT" then
        res:set_status(STATUS.METHOD_NOT_ALLOWED)
        res:write_json({
            success = false,
            error = "Method not allowed. Use PUT."
        })
        return
    end

    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Component ID is required in URL path"
        })
        return
    end

    local body, parse_err = req:body_json()
    if parse_err then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Invalid JSON request body: " .. parse_err
        })
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

    -- Open the component with credentials contract and WRITE access
    local cred_component, comp_err = component.open(component_id, component.ACCESS.WRITE, CREDENTIALS_CONTRACT)
    if comp_err then
        res:set_status(STATUS.FORBIDDEN)
        res:write_json({
            success = false,
            error = comp_err
        })
        return
    end

    -- Get existing credentials info to find provider
    local existing_info, info_err = cred_component:get_info({})
    if info_err then
        res:set_status(STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "Connection not found: " .. info_err
        })
        return
    end

    local provider_name = existing_info.metadata and existing_info.metadata.provider
    if not provider_name then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Connection missing provider information"
        })
        return
    end

    -- Get discovery service to validate against provider schema
    local discovery_service, err = contract.get(DISCOVERY_SERVICE_CONTRACT)
    if err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Discovery service not available: " .. err
        })
        return
    end

    local discovery_instance, err = discovery_service:open()
    if err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to open discovery service: " .. err
        })
        return
    end

    local provider_info, err = discovery_instance:get_provider_info({
        credential_provider = provider_name
    })

    if err then
        res:set_status(STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "Provider not found: " .. err
        })
        return
    end

    -- Validate the new credentials
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

    -- Store updated credentials (only technical metadata in credentials)
    local store_request = {
        public_data = {},
        private_data = normalized_credentials,
        metadata = existing_info.metadata or {}
    }

    -- Update technical metadata if provided (server versions, API endpoints, etc.)
    if body.metadata and type(body.metadata) == "table" then
        for key, value in pairs(body.metadata) do
            store_request.metadata[key] = value
        end
    end

    local store_result, store_err = cred_component:store_credentials(store_request)
    if store_err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to update credentials: " .. store_err
        })
        return
    end

    if not store_result.success then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = store_result.error or "Failed to update credentials"
        })
        return
    end

    -- Update component metadata (title and description) using component service
    -- Use component.get_service() shortcut instead of manual contract getting
    local service, err = component.get_service()
    if err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to get component service: " .. err
        })
        return
    end

    -- Update component metadata with title and description
    local update_commands = {
        {
            type = "PUT_META",
            payload = {
                title = body.connection_name,
                description = body.connection_description or ""
            }
        }
    }

    local update_result, update_err = service:update_component({
        component_id = component_id,
        commands = update_commands
    })

    if update_err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to update component metadata: " .. update_err
        })
        return
    end

    -- Return success response
    res:set_status(STATUS.OK)
    res:write_json({
        success = true,
        component_id = component_id,
        connection_name = body.connection_name,
        provider = {
            name = provider_info.name,
            title = provider_info.title
        },
        updated_at = store_result.updated_at
    })
end

return {
    handler = handler
}
