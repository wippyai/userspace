local contract = require("contract")
local security = require("security")

-- Constants
local DISCOVERY_SERVICE_CONTRACT = "userspace.component.discovery:component_discovery"

local function handle(params)
    params = params or {}

    local actor = security.actor()
    if not actor then
        return { error = "Authentication required" }
    end

    local driver_type = params.driver_type or "all"

    -- Get discovery service contract (same as the working UI)
    local discovery_service, err = contract.get(DISCOVERY_SERVICE_CONTRACT)
    if not discovery_service then
        return {
            error = "Failed to get discovery service: " .. (err or "unknown error"),
            debug = { contract_error = err }
        }
    end

    -- Open the service
    local service, err = discovery_service:open()
    if not service then
        return {
            error = "Failed to open discovery service: " .. (err or "unknown error"),
            debug = { open_error = err }
        }
    end

    -- Build request DTO based on driver type
    local request_dto = {
        include_ui_bindings = true
    }

    -- Add filters for connection types
    local filters = {}

    if driver_type == "oauth" then
        filters.classes = { "oauth_connection" }
    elseif driver_type == "credentials" then
        filters.classes = { "credential_connection" }
    else -- driver_type == "all"
        filters.classes = { "oauth_connection", "credential_connection" }
    end

    request_dto.filters = filters

    -- Call the discovery service (same method as working UI)
    local result, err = service:list_available_components(request_dto)
    if not result then
        return {
            error = "Service call failed: " .. (err or "unknown error"),
            debug = { call_error = err }
        }
    end

    -- Check if service returned an error
    if not result.success then
        return {
            error = result.error or "Service returned error",
            debug = { service_error = result.error }
        }
    end

    -- Map the components to providers format and add driver_type
    local providers = {}
    for _, component in ipairs(result.components or {}) do
        -- Determine driver type from component class
        local component_driver_type = "unknown"
        if component.classes then
            for _, class in ipairs(component.classes) do
                if class == "oauth_connection" then
                    component_driver_type = "oauth"
                    break
                elseif class == "credential_connection" then
                    component_driver_type = "credentials"
                    break
                end
            end
        end

        -- Add driver_type to component
        component.driver_type = component_driver_type
        table.insert(providers, component)
    end

    return {
        providers = providers,
        total_count = #providers,
        driver_type_filter = driver_type,
        success = true
    }
end

return { handle = handle }