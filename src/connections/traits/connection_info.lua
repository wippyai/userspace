local contract = require("contract")
local security = require("security")

-- Constants
local COMPONENT_SERVICE_CONTRACT = "userspace.component:component_service"
local OAUTH_CONNECTION_CONTRACT = "userspace.oauth:oauth_connection_contract"
local CREDENTIALS_CONTRACT = "userspace.credentials:credentials_contract"
local COMPONENT_CONTRACT = "userspace.contract:component"

local function handle(params)
    if not params or not params.component_id then
        return {
            error = "Component ID is required"
        }
    end

    local actor = security.actor()
    if not actor then
        return {
            error = "Authentication required"
        }
    end

    local component_id = params.component_id

    -- First, get basic component info from component service
    local comp_service, err = contract.get(COMPONENT_SERVICE_CONTRACT)
    if not comp_service then
        return {
            error = "Component service not found: " .. (err or "unknown error")
        }
    end

    local service_instance, err = comp_service:open()
    if not service_instance then
        return {
            error = "Failed to open component service: " .. (err or "unknown error")
        }
    end

    -- Get component metadata
    local comp_result, err = service_instance:get_component({
        component_id = component_id
    })

    if not comp_result then
        return {
            error = "Failed to get component: " .. (err or "unknown error")
        }
    end

    if not comp_result.success then
        return {
            error = comp_result.error or "Component not found"
        }
    end

    local component = comp_result
    local meta = component.meta or {}

    -- Determine connection type from metadata
    local connection_type = "unknown"
    if meta.oauth_connection == "true" or meta.oauth_connection == true then
        connection_type = "oauth"
    elseif meta.credential_connection == "true" or meta.credential_connection == true then
        connection_type = "credentials"
    end

    -- Build response maintaining your structure
    local response = {
        success = true,
        component_id = component_id,
        connection_type = connection_type,
        meta = meta,
        component = {
            impl_id = component.impl_id,
            created_at = component.created_at,
            updated_at = component.updated_at
        }
    }

    -- Try to get detailed connection info based on type
    if connection_type == "oauth" then
        local oauth_contract, err = contract.get(OAUTH_CONNECTION_CONTRACT)
        if oauth_contract then
            local instance, err = oauth_contract:open("userspace.oauth:oauth_connection", {component_id = component_id})
            if instance then
                local info_result, err = instance:get_info({})
                if info_result then
                    response.detailed_info = info_result
                    response.has_detailed_info = true
                else
                    response.detailed_error = err or "Failed to get OAuth info"
                    response.has_detailed_info = false
                end
            else
                response.detailed_error = "Failed to open OAuth connection: " .. (err or "unknown error")
                response.has_detailed_info = false
            end
        else
            response.detailed_error = "OAuth contract not available: " .. (err or "unknown error")
            response.has_detailed_info = false
        end

    elseif connection_type == "credentials" then
        local cred_contract, err = contract.get(CREDENTIALS_CONTRACT)
        if cred_contract then
            local instance, err = cred_contract:open("userspace.credentials:credentials_store", {component_id = component_id})
            if instance then
                local info_result, err = instance:get_info({})
                if info_result then
                    response.detailed_info = info_result
                    response.has_detailed_info = true
                else
                    response.detailed_error = err or "Failed to get credentials info"
                    response.has_detailed_info = false
                end
            else
                response.detailed_error = "Failed to open credentials connection: " .. (err or "unknown error")
                response.has_detailed_info = false
            end
        else
            response.detailed_error = "Credentials contract not available: " .. (err or "unknown error")
            response.has_detailed_info = false
        end
    else
        response.detailed_error = "Unknown connection type or not a connection component"
        response.has_detailed_info = false
    end

    -- Get component status (available for both OAuth and credentials)
    local comp_contract, err = contract.get(COMPONENT_CONTRACT)
    if comp_contract then
        local impl_id = component.impl_id
        if type(impl_id) ~= "string" or impl_id == "" then
            response.status_error = "Component implementation ID is missing"
            return response
        end

        local status_instance, err = comp_contract:open(impl_id, {component_id = component_id})
        if status_instance then
            local status_result, err = status_instance:get_status({})
            if status_result then
                response.status_info = status_result
            else
                response.status_error = err or "Failed to get status"
            end
        else
            response.status_error = "Failed to open component for status: " .. (err or "unknown error")
        end
    else
        response.status_error = "Component contract not available: " .. (err or "unknown error")
    end

    return response
end

return { handle = handle }
