local http = require("http")
local json = require("json")
local contract = require("contract")
local component = require("component")
local credentials_repo = require("credentials_repo")
local api_error = require("api_error")

local DISCOVERY_SERVICE_CONTRACT = "userspace.credentials.discovery:provider_discovery"

-- Function to filter out sensitive credentials based on provider UI config
local function filter_sensitive_credentials(credentials, sensitive_fields)
    if not credentials or type(credentials) ~= "table" then
        return {}
    end

    -- Default sensitive fields if none specified (common sensitive field names)
    if not sensitive_fields or type(sensitive_fields) ~= "table" then
        sensitive_fields = {
            "password", "secret", "token", "key", "api_key", "api_token",
            "access_token", "refresh_token", "personal_access_token",
            "private_key", "certificate", "passphrase", "auth_token"
        }
    end

    local filtered_credentials = {}

    -- Include all non-sensitive fields
    for field_name, field_value in pairs(credentials) do
        local is_sensitive = false

        -- Check if field is explicitly marked as sensitive
        for _, sensitive_field in ipairs(sensitive_fields) do
            if field_name == sensitive_field then
                is_sensitive = true
                break
            end
        end

        -- Also check for common sensitive patterns in field names (case-insensitive)
        if not is_sensitive then
            local lower_field = string.lower(field_name)
            if string.find(lower_field, "password") or
               string.find(lower_field, "secret") or
               string.find(lower_field, "token") or
               string.find(lower_field, "key") then
                is_sensitive = true
            end
        end

        -- Include non-sensitive fields (including nested objects like server_info)
        if not is_sensitive then
            filtered_credentials[field_name] = field_value
        end
    end

    return filtered_credentials
end

-- Function to mask sensitive values for debugging display
local function mask_sensitive_values(credentials, sensitive_fields)
    if not credentials or type(credentials) ~= "table" then
        return {}
    end

    local masked_credentials = {}

    -- Copy all fields, replacing sensitive ones with [REDACTED]
    for field_name, field_value in pairs(credentials) do
        local is_sensitive = false

        -- Check if field is explicitly marked as sensitive
        for _, sensitive_field in ipairs(sensitive_fields) do
            if field_name == sensitive_field then
                is_sensitive = true
                break
            end
        end

        if is_sensitive and field_value and field_value ~= "" then
            masked_credentials[field_name] = "[REDACTED]"
        else
            masked_credentials[field_name] = field_value
        end
    end

    return masked_credentials
end

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    res:set_content_type(http.CONTENT.JSON)

    if req:method() ~= "GET" then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:write_json({
            success = false,
            error = "Method not allowed. Use GET."
        })
        return
    end

    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Component ID is required"
        })
        return
    end

    local access_level, access_err = component.validate_access(component_id, 1)
    if not access_level or access_level == 0 then
        api_error.fail(res, http.STATUS.FORBIDDEN, "Insufficient permissions to view this connection", access_err)
        return
    end

    local connection, err = credentials_repo.get_credentials(component_id)
    if err then
        api_error.fail(res, http.STATUS.NOT_FOUND, "Credential connection not found", err)
        return
    end

    local provider_name = connection.metadata and connection.metadata.provider
    if not provider_name then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Connection missing provider information"
        })
        return
    end

    local discovery_service, err = contract.get(DISCOVERY_SERVICE_CONTRACT)
    if err then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Discovery service not available", err)
        return
    end

    local discovery_instance, err = discovery_service:open()
    if err then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to open discovery service", err)
        return
    end

    local provider_info, err = discovery_instance:get_provider_info({
        credential_provider = provider_name
    })

    if err then
        provider_info = {
            name = provider_name,
            title = provider_name,
            description = "Credential provider",
            credential_schema = {},
            ui_config = {}
        }
    end

    -- Get component metadata for title and description AND implementation ID
    local service, err = component.get_service()
    local component_metadata = {}
    local impl_id = nil
    if service then
        local comp_info, comp_err = service:get_component({
            component_id = component_id
        })
        if comp_info and not comp_err then
            component_metadata = comp_info.meta or {}
            impl_id = comp_info.impl_id  -- This is the key addition - get the implementation ID
        end
    end

    -- Filter out sensitive credentials based on provider UI config
    local sensitive_fields = provider_info.ui_config and provider_info.ui_config.sensitive_fields or {}
    local filtered_credentials = filter_sensitive_credentials(connection.credentials, sensitive_fields)
    local debug_credentials = mask_sensitive_values(connection.credentials, sensitive_fields)

    local response = {
        success = true,
        connection = {
            component_id = connection.component_id,
            connection_name = connection.connection_name,
            connection_description = connection.connection_description,
            -- Add component metadata (title, description from component service)
            component_title = component_metadata.title,
            component_description = component_metadata.description,
            created_at = connection.created_at,
            updated_at = connection.updated_at,
            provider = provider_name,
            provider_title = provider_info.title,
            provider_icon = provider_info.icon,
            provider_description = provider_info.description,
            -- Return filtered (non-sensitive) credentials
            credentials = filtered_credentials,
            -- Also return debug credentials structure with sensitive values masked
            credentials_debug = debug_credentials,
            metadata = connection.metadata or {},
            component_metadata = component_metadata,
            -- ADD: Implementation ID for component reference
            impl_id = impl_id
        },
        provider = {
            id = provider_info.id,
            name = provider_info.name,
            title = provider_info.title,
            description = provider_info.description,
            icon = provider_info.icon,
            credential_provider = provider_info.credential_provider,
            group = provider_info.group,
            credential_schema = provider_info.credential_schema or {},
            ui_config = provider_info.ui_config or {}
        },
        access_level = access_level
    }

    res:set_status(http.STATUS.OK)
    res:write_json(response)
end

return {
    handler = handler
}