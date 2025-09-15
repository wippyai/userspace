local registry = require("registry")
local json = require("json")

-- Create the module table
local component_registry = {}

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

-- Helper function to search in text fields
local function matches_search(search_term, name, description, classes)
    if not search_term or search_term == "" then
        return true
    end

    local search_lower = search_term:lower()

    -- Search in name
    if name and name:lower():find(search_lower, 1, true) then
        return true
    end

    -- Search in description
    if description and description:lower():find(search_lower, 1, true) then
        return true
    end

    -- Search in classes
    for _, class in ipairs(classes) do
        if class:lower():find(search_lower, 1, true) then
            return true
        end
    end

    return false
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

-- Scan registry for all available component contracts
function component_registry.scan_available_components(filters, include_ui_bindings)
    filters = filters or {}
    include_ui_bindings = include_ui_bindings ~= false -- Default to true

    -- Find all contract definitions with meta.type=component
    local component_contracts, err = registry.find({
        ["meta.type"] = "component"
    })

    if err then
        return nil, "Failed to scan registry: " .. err
    end

    if not component_contracts then
        component_contracts = {}
    end

    local components = {}
    local all_classes = {}

    for _, contract in ipairs(component_contracts) do
        local namespace, name = parse_registry_id(contract.id)
        if namespace and name then
            local component_name = (contract.meta and contract.meta.name) or name
            local description = (contract.meta and contract.meta.comment) or ""
            local icon = nil
            if contract.meta and contract.meta.component and contract.meta.component.icon then
                icon = contract.meta.component.icon
            end
            local classes = normalize_classes(contract.meta and contract.meta.class)

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

            -- Apply filters
            local include = true

            -- Filter by classes
            if filters.classes and #filters.classes > 0 then
                if not arrays_intersect(filters.classes, classes) then
                    include = false
                end
            end

            -- Filter by namespaces
            if include and filters.namespaces and #filters.namespaces > 0 then
                local namespace_match = false
                for _, filter_ns in ipairs(filters.namespaces) do
                    if namespace == filter_ns then
                        namespace_match = true
                        break
                    end
                end
                if not namespace_match then
                    include = false
                end
            end

            -- Filter by search term
            if include and filters.search then
                if not matches_search(filters.search, component_name, description, classes) then
                    include = false
                end
            end

            if include then
                local component_info = {
                    id = contract.id,
                    name = component_name,
                    description = description,
                    classes = classes,
                    namespace = namespace
                }

                if icon then
                    component_info.icon = icon
                end

                -- Add UI bindings if requested
                if include_ui_bindings and contract.meta and contract.meta.component then
                    if contract.meta.component.create_ui_id then
                        component_info.create_ui_id = contract.meta.component.create_ui_id
                    end
                    if contract.meta.component.manage_ui_id then
                        component_info.manage_ui_id = contract.meta.component.manage_ui_id
                    end
                end

                table.insert(components, component_info)
            end
        end
    end

    -- Sort classes alphabetically
    table.sort(all_classes)

    return {
        components = components,
        total_count = #components,
        available_classes = all_classes
    }
end

-- Get detailed information about a specific component contract
function component_registry.get_component_info(component_id)
    if not component_id or component_id == "" then
        return nil, "Component ID is required"
    end

    -- Get the contract definition
    local contract, err = registry.get(component_id)
    if err then
        return nil, "Failed to get component: " .. err
    end

    if not contract then
        return nil, "Component not found: " .. component_id
    end

    -- Verify it's a component contract
    if contract.kind ~= "contract.definition" or
        not contract.meta or
        contract.meta.type ~= "component" then
        return nil, "Entry is not a component contract: " .. component_id
    end

    local namespace, name = parse_registry_id(contract.id)
    if not namespace or not name then
        return nil, "Invalid component ID format: " .. component_id
    end

    local component_name = (contract.meta and contract.meta.name) or name
    local description = (contract.meta and contract.meta.comment) or ""
    local icon = nil
    if contract.meta and contract.meta.component and contract.meta.component.icon then
        icon = contract.meta.component.icon
    end
    local classes = normalize_classes(contract.meta and contract.meta.class)

    -- Process methods
    local methods = {}
    if contract.methods then
        for _, method in ipairs(contract.methods) do
            table.insert(methods, {
                name = method.name,
                description = method.description or "",
                input_schemas = method.input_schemas or {},
                output_schemas = method.output_schemas or {}
            })
        end
    end

    local result = {
        id = contract.id,
        name = component_name,
        description = description,
        classes = classes,
        namespace = namespace,
        methods = methods
    }

    if icon then
        result.icon = icon
    end

    -- Add UI bindings from meta.component
    if contract.meta and contract.meta.component then
        if contract.meta.component.create_ui_id then
            result.create_ui_id = contract.meta.component.create_ui_id
        end
        if contract.meta.component.manage_ui_id then
            result.manage_ui_id = contract.meta.component.manage_ui_id
        end
    end

    return result
end

return component_registry
