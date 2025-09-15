local registry = require("registry")
local json = require("json")

local DEFAULT_COMPONENT_CONTRACT = "userspace.credentials:credentials_store"

local provider_registry = {}

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

local function normalize_tags(tags)
    if not tags then
        return {}
    end

    if type(tags) == "string" then
        return { tags }
    elseif type(tags) == "table" then
        local result = {}
        for _, tag in ipairs(tags) do
            if type(tag) == "string" and tag ~= "" then
                table.insert(result, tag)
            end
        end
        return result
    end

    return {}
end

local function parse_registry_id(id)
    if not id or type(id) ~= "string" then
        return nil, nil
    end

    local namespace, name = id:match("^(.+):([^:]+)$")
    return namespace, name
end

local function arrays_intersect(arr1, arr2)
    if not arr1 or #arr1 == 0 then
        return true
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

local function add_unique_to_array(arr, item)
    if not item or item == "" then
        return
    end

    for _, existing in ipairs(arr) do
        if existing == item then
            return
        end
    end

    table.insert(arr, item)
end

local function find_provider_entry(provider_id, credential_provider)
    local entry = nil
    local err = nil

    if provider_id and provider_id ~= "" then
        entry, err = registry.get(provider_id)
        if err then
            return nil, "Failed to get provider by ID: " .. err
        end
    end

    if not entry and credential_provider and credential_provider ~= "" then
        local entries, find_err = registry.find({
            ["meta.credential_provider"] = credential_provider
        })

        if find_err then
            return nil, "Failed to search by credential_provider: " .. find_err
        end

        if entries and #entries > 0 then
            entry = entries[1]
        end
    end

    if not entry then
        local search_term = provider_id or credential_provider or "unknown"
        return nil, "Credential provider not found: " .. search_term
    end

    if not entry.meta or not entry.meta.credential_provider then
        return nil, "Entry is not a credential provider: " .. (entry.id or "unknown")
    end

    return entry, nil
end

function provider_registry.scan_available_providers(filters)
    filters = filters or {}

    local provider_entries, err = registry.find({
        ["*meta.credential_provider"] = "*"
    })

    if err then
        return nil, "Failed to scan registry: " .. err
    end

    if not provider_entries then
        provider_entries = {}
    end

    local providers = {}
    local all_groups = {}
    local all_classes = {}

    for _, entry in ipairs(provider_entries) do
        local namespace, name = parse_registry_id(entry.id)
        if namespace and name and entry.meta then
            local provider_name = entry.meta.name or name
            local title = entry.meta.title or provider_name
            local description = entry.meta.comment or entry.meta.description or ""
            local credential_provider = entry.meta.credential_provider
            local group = entry.meta.group or "Other"
            local icon = nil

            if entry.meta.component and entry.meta.component.icon then
                icon = entry.meta.component.icon
            end

            local classes = normalize_classes(entry.meta.class)
            local tags = normalize_tags(entry.meta.tags)

            add_unique_to_array(all_groups, group)
            for _, class in ipairs(classes) do
                add_unique_to_array(all_classes, class)
            end

            local include = true

            if filters.groups and #filters.groups > 0 then
                local group_match = false
                for _, filter_group in ipairs(filters.groups) do
                    if filter_group == group then
                        group_match = true
                        break
                    end
                end
                if not group_match then
                    include = false
                end
            end

            if include and filters.classes and #filters.classes > 0 then
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
                    credential_provider = credential_provider,
                    group = group,
                    classes = classes,
                    tags = tags,
                    namespace = namespace
                }

                if icon then
                    provider_info.icon = icon
                end

                if entry.meta.component then
                    if entry.meta.component.create_ui_id then
                        provider_info.create_ui_id = entry.meta.component.create_ui_id
                    end
                    if entry.meta.component.manage_ui_id then
                        provider_info.manage_ui_id = entry.meta.component.manage_ui_id
                    end
                end

                if entry.data then
                    if entry.data.credential_schema then
                        provider_info.credential_schema = entry.data.credential_schema
                    end
                    if entry.data.ui_config then
                        provider_info.ui_config = entry.data.ui_config
                    end
                end

                table.insert(providers, provider_info)
            end
        end
    end

    table.sort(all_groups)
    table.sort(all_classes)

    return {
        providers = providers,
        total_count = #providers,
        available_groups = all_groups,
        available_classes = all_classes
    }
end

function provider_registry.get_provider_info(provider_id, credential_provider)
    local entry, err = find_provider_entry(provider_id, credential_provider)
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
    local credential_provider_value = entry.meta.credential_provider
    local group = entry.meta.group or "Other"
    local icon = nil

    if entry.meta.component and entry.meta.component.icon then
        icon = entry.meta.component.icon
    end

    local classes = normalize_classes(entry.meta.class)
    local tags = normalize_tags(entry.meta.tags)

    local result = {
        id = entry.id,
        name = provider_name,
        title = title,
        description = description,
        credential_provider = credential_provider_value,
        group = group,
        classes = classes,
        tags = tags,
        namespace = namespace
    }

    if icon then
        result.icon = icon
    end

    if entry.meta.component then
        if entry.meta.component.create_ui_id then
            result.create_ui_id = entry.meta.component.create_ui_id
        end
        if entry.meta.component.manage_ui_id then
            result.manage_ui_id = entry.meta.component.manage_ui_id
        end
    end

    result.credential_schema = (entry.data and entry.data.credential_schema) or {}
    result.ui_config = (entry.data and entry.data.ui_config) or {}

    if entry.data and entry.data.validation_contract_id then
        result.validation_contract_id = entry.data.validation_contract_id
    end

    return result
end

function provider_registry.get_component_contract(provider_id, credential_provider)
    local entry, err = find_provider_entry(provider_id, credential_provider)
    if not entry then
        return nil, err
    end

    local component_contract_id = DEFAULT_COMPONENT_CONTRACT
    if entry.data and entry.data.component_contract_id and entry.data.component_contract_id ~= "" then
        component_contract_id = entry.data.component_contract_id
    end

    return {
        component_contract_id = component_contract_id,
        provider_id = entry.id,
        credential_provider = entry.meta.credential_provider
    }
end

return provider_registry