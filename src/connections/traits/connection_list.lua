local contract = require("contract")
local security = require("security")

-- Constants
local COMPONENT_SERVICE_CONTRACT = "userspace.component:component_service"

local function handle(params)
    params = params or {}

    local actor = security.actor()
    if not actor then
        return { error = "Authentication required" }
    end

    local connection_type = params.connection_type or "all"
    local limit = params.limit or 50

    if limit < 1 or limit > 100 then
        return { error = "Limit must be between 1 and 100" }
    end

    -- Get component service
    local comp_service, err = contract.get(COMPONENT_SERVICE_CONTRACT)
    if not comp_service then
        return { error = "Component service not found: " .. (err or "unknown error") }
    end

    local service_instance, err = comp_service:open()
    if not service_instance then
        return { error = "Failed to open component service: " .. (err or "unknown error") }
    end

    -- Build filters - use "connection" class like the working UI does
    local filters = {
        meta = { class = "connection" }
    }

    -- List connections (same as working UI)
    local result, err = service_instance:list_components({
        filters = filters,
        pagination = {
            limit = limit,
            offset = 0
        }
    })

    if not result then
        return { error = "Failed to list connections: " .. (err or "unknown error") }
    end

    if not result.success then
        return { error = result.error or "Service returned error" }
    end

    -- Filter by connection_type if not "all"
    local filtered_components = {}
    if connection_type == "all" then
        filtered_components = result.components or {}
    else
        for _, component in ipairs(result.components or {}) do
            local meta = component.meta or {}

            -- Check for OAuth connection indicators
            if connection_type == "oauth" then
                if meta.oauth_connection or
                   (meta.class and string.find(tostring(meta.class), "oauth")) or
                   (meta.type and string.find(string.lower(tostring(meta.type)), "oauth")) then
                    table.insert(filtered_components, component)
                end
            -- Check for credential connection indicators
            elseif connection_type == "credentials" then
                if meta.credential_connection or
                   (meta.class and string.find(tostring(meta.class), "credential")) or
                   (meta.type and string.find(string.lower(tostring(meta.type)), "credential")) then
                    table.insert(filtered_components, component)
                end
            end
        end
    end

    return {
        success = true,
        components = filtered_components,
        total_count = #filtered_components,
        has_more = result.has_more or false
    }
end

return { handle = handle }