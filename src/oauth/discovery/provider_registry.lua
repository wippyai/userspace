local registry = require("registry")
local json = require("json")

-- Constants
local DEFAULT_COMPONENT_CONTRACT = "userspace.oauth:oauth_connection"

-- Create the module table
local provider_registry = {}

-- Helper function to normalize classes to array
local function normalize_classes(classes)
    if not classes then
        return {}
    end

    if type(classes) == "string" then
        return { classes }
    elseif type(classes) == "table" then
        local result = {}
        for _, class in ipairs(classes) do
            if type(class) == "string" and class ~= "" then
                table.insert(result, class)
            end
        end
        return result
    end

    return {}
end

-- Helper function to parse registry ID
local function parse_registry_id(id)
    if not id or type(id) ~= "string" then
        return nil, nil
    end

    local namespace, name = id:match("^(.+):([^:]+)$")
    return namespace, name
end

-- Helper function to check if arrays have intersection
local function arrays_intersect(arr1, arr2)
    if not arr1 or #arr1 == 0 then
        return true -- No filter means all match
    end

    for _, item1 in ipairs(arr1) do
        for _, item2 in ipairs(arr2) do
            if item1 == item2 then
                return true
            end
        end
    end

    return false
end

-- Helper function to find provider entry
local function find_provider_entry(provider_id, oauth_provider)
    local entry = nil
    local err = nil

    -- Try to find by provider_id first
    if provider_id and provider_id ~= "" then
        entry, err = registry.get(provider_id)
        if err then
            return nil, "Failed to get provider by ID: " .. err
        end
    end

    -- If not found by ID or no ID provided, try to find by oauth_provider field
    if not entry and oauth_provider and oauth_provider ~= "" then
        local entries, find_err = registry.find({
            ["meta.oauth_provider"] = oauth_provider
        })

        if find_err then
            return nil, "Failed to search by oauth_provider: " .. find_err
        end

        if entries and #entries > 0 then
            entry = entries[1] -- Take first match
        end
    end

    if not entry then
        local search_term = provider_id or oauth_provider or "unknown"
        return nil, "OAuth provider not found: " .. search_term
    end

    -- Verify it has oauth_provider metadata
    if not entry.meta or not entry.meta.oauth_provider then
        return nil, "Entry is not an OAuth provider: " .. (entry.id or "unknown")
    end

    return entry, nil
end

-- Scan registry for all available OAuth providers
function provider_registry.scan_available_providers(filters)
    filters = filters or {}

    -- Find all registry entries that have meta.oauth_provider field
    local provider_entries, err = registry.find({
        ["*meta.oauth_provider"] = "*"
    })

    if err then
        return nil, "Failed to scan registry: " .. err
    end

    if not provider_entries then
        provider_entries = {}
    end

    local providers = {}
    local all_classes = {}

    for _, entry in ipairs(provider_entries) do
        local namespace, name = parse_registry_id(entry.id)
        if namespace and name and entry.meta then
            local provider_name = entry.meta.name or name
            local title = entry.meta.title or provider_name
            local description = entry.meta.comment or entry.meta.description or ""
            local oauth_provider = entry.meta.oauth_provider
            local icon = nil

            if entry.meta.component and entry.meta.component.icon then
                icon = entry.meta.component.icon
            end

            local classes = normalize_classes(entry.meta.class)

            -- Collect all classes for filtering
            for _, class in ipairs(classes) do
                local found = false
                for _, existing_class in ipairs(all_classes) do
                    if existing_class == class then
                        found = true
                        break
                    end
                end
                if not found then
                    table.insert(all_classes, class)
                end
            end

            -- Apply filters - only class filtering
            local include = true

            -- Filter by classes
            if filters.classes and #filters.classes > 0 then
                if not arrays_intersect(filters.classes, classes) then
                    include = false
                end
            end

            if include then
                local provider_info = {
                    id = entry.id,
                    name = provider_name,
                    title = title,
                    description = description,
                    oauth_provider = oauth_provider,
                    classes = classes,
                    namespace = namespace
                }

                if icon then
                    provider_info.icon = icon
                end

                -- Add UI bindings if available
                if entry.meta.component then
                    if entry.meta.component.create_ui_id then
                        provider_info.create_ui_id = entry.meta.component.create_ui_id
                    end
                    if entry.meta.component.manage_ui_id then
                        provider_info.manage_ui_id = entry.meta.component.manage_ui_id
                    end
                end

                -- Extract scopes from entry.data
                provider_info.default_scopes = (entry.data and entry.data.default_scopes) or {}
                provider_info.available_scopes = (entry.data and entry.data.available_scopes) or {}

                table.insert(providers, provider_info)
            end
        end
    end

    -- Sort classes alphabetically
    table.sort(all_classes)

    return {
        providers = providers,
        total_count = #providers,
        available_classes = all_classes
    }
end

-- Get detailed information about a specific OAuth provider
function provider_registry.get_provider_info(provider_id, oauth_provider)
    local entry, err = find_provider_entry(provider_id, oauth_provider)
    if not entry then
        return nil, err
    end

    local namespace, name = parse_registry_id(entry.id)
    if not namespace or not name then
        return nil, "Invalid provider ID format: " .. (entry.id or "unknown")
    end

    local provider_name = entry.meta.name or name
    local title = entry.meta.title or provider_name
    local description = entry.meta.comment or entry.meta.description or ""
    local oauth_provider_value = entry.meta.oauth_provider
    local icon = nil

    if entry.meta.component and entry.meta.component.icon then
        icon = entry.meta.component.icon
    end

    local classes = normalize_classes(entry.meta.class)

    local result = {
        id = entry.id,
        name = provider_name,
        title = title,
        description = description,
        oauth_provider = oauth_provider_value,
        classes = classes,
        namespace = namespace
    }

    if icon then
        result.icon = icon
    end

    -- Add UI bindings from meta.component
    if entry.meta.component then
        if entry.meta.component.create_ui_id then
            result.create_ui_id = entry.meta.component.create_ui_id
        end
        if entry.meta.component.manage_ui_id then
            result.manage_ui_id = entry.meta.component.manage_ui_id
        end
    end

    -- Extract scopes from entry.data
    result.default_scopes = (entry.data and entry.data.default_scopes) or {}
    result.available_scopes = (entry.data and entry.data.available_scopes) or {}

    return result
end

-- Get connector contract implementation and context values for a provider
function provider_registry.get_connector_contract(provider_id, oauth_provider)
    local entry, err = find_provider_entry(provider_id, oauth_provider)
    if not entry then
        return nil, err
    end

    -- Verify it has connector_contract configuration in data
    if not entry.data or not entry.data.connector_contract then
        return nil, "Provider has no connector_contract configuration: " .. (entry.id or "unknown")
    end

    local connector_contract = entry.data.connector_contract
    if type(connector_contract) ~= "table" then
        return nil, "Invalid connector_contract format: " .. (entry.id or "unknown")
    end

    if not connector_contract.implementation_id or connector_contract.implementation_id == "" then
        return nil, "Missing implementation_id in connector_contract: " .. (entry.id or "unknown")
    end

    local context_values = connector_contract.context_values or {}
    if type(context_values) ~= "table" then
        return nil, "Invalid context_values format: " .. (entry.id or "unknown")
    end

    return {
        provider_id = entry.id,
        oauth_provider = entry.meta.oauth_provider,
        implementation_id = connector_contract.implementation_id,
        context_values = context_values
    }
end

-- Get component contract ID for registering OAuth connection components
function provider_registry.get_component_contract(provider_id, oauth_provider)
    local entry, err = find_provider_entry(provider_id, oauth_provider)
    if not entry then
        return nil, err
    end

    -- Check if provider has custom component_contract specified
    local component_contract_id = DEFAULT_COMPONENT_CONTRACT
    if entry.data and entry.data.component_contract and entry.data.component_contract ~= "" then
        component_contract_id = entry.data.component_contract
    end

    return {
        component_contract_id = component_contract_id,
        provider_id = entry.id,
        oauth_provider = entry.meta.oauth_provider
    }
end

return provider_registry