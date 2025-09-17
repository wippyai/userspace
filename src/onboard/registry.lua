local registry = require("registry")
local security = require("security")

-- Main module
local onboard_registry = {}

-- Find all resources in the registry
local function find_all_resources()
    local entries, err = registry.find({
        [".kind"] = "registry.entry",
        ["meta.type"] = "view.resource"
    })

    if err then
        return nil, "Failed to find resources: " .. err
    end

    if not entries or #entries == 0 then
        return {}
    end

    local result = {}
    for _, entry in ipairs(entries) do
        if entry.meta then
            local resource = {
                id = entry.id,
                name = entry.meta.name or "",
                resource_type = entry.meta.resource_type or "other",
                order = entry.meta.order or 9999,
                global = entry.meta.global or false,
                template_set = entry.meta.template_set,
                url = entry.meta.url,
                inline = entry.meta.inline,
                integrity = entry.meta.integrity,
                crossorigin = entry.meta.crossorigin,
                media = entry.meta.media,
                defer = entry.meta.defer,
                async = entry.meta.async,
            }
            result[entry.id] = resource
        end
    end

    return result
end

-- Group resources by type
local function group_resources_by_type(resources_list)
    local grouped = {}

    for id, resource in pairs(resources_list) do
        local resource_type = resource.resource_type

        if not grouped[resource_type] then
            grouped[resource_type] = {}
        end

        table.insert(grouped[resource_type], resource)
    end

    -- Sort each group by order
    for _, group in pairs(grouped) do
        table.sort(group, function(a, b)
            return a.order < b.order
        end)
    end

    return grouped
end

-- Collect resources for a template set
local function collect_resources_for_template_set(template_set_id, all_resources)
    if not all_resources then
        local res_list, err = find_all_resources()
        if err then
            return {}, "Failed to collect resources: " .. err
        end
        all_resources = res_list
    end

    local template_resources = {}

    -- Add global resources
    for id, resource in pairs(all_resources) do
        if resource.global then
            template_resources[id] = resource
        end
    end

    -- Add template-set specific resources
    for id, resource in pairs(all_resources) do
        if resource.template_set and resource.template_set == template_set_id then
            template_resources[id] = resource
        end
    end

    return template_resources
end

-- Find all onboarding steps (now looking for jet templates)
function onboard_registry.find_all()
    local entries, err = registry.find({
        [".kind"] = "template.jet",
        ["meta.type"] = "onboard.step"
    })

    if err then
        return nil, "Failed to find onboarding steps: " .. err
    end

    if not entries or #entries == 0 then
        return {}
    end

    local steps = {}
    for _, entry in ipairs(entries) do
        if entry.meta then
            local step = {
                id = entry.id,
                name = entry.meta.name,
                title = entry.meta.title or entry.meta.name,
                description = entry.meta.description or "",
                order = entry.meta.order or 9999,
                optional = entry.meta.optional or false,
                tutorial = entry.meta.tutorial or false,
                template_name = entry.meta.name
            }
            table.insert(steps, step)
        end
    end

    -- Sort by order
    table.sort(steps, function(a, b)
        return a.order < b.order
    end)

    return steps
end

-- Get step by name with resources
function onboard_registry.get_by_name(step_name)
    if not step_name then
        return nil, "Step name is required"
    end

    local entries, err = registry.find({
        [".kind"] = "template.jet",
        ["meta.type"] = "onboard.step",
        ["meta.name"] = step_name
    })

    if err then
        return nil, "Failed to find step: " .. err
    end

    if not entries or #entries == 0 then
        return nil, "Step not found: " .. step_name
    end

    local entry = entries[1]
    if not entry.meta then
        return nil, "Invalid step entry"
    end

    -- Get all available resources
    local all_resources, res_err = find_all_resources()
    if res_err then
        return nil, "Failed to find resources: " .. res_err
    end

    -- Collect resources for this step (like the original page registry did)
    local step_resources = {}
    local template_set = entry.data.set

    -- Add global resources
    for id, resource in pairs(all_resources) do
        if resource.global then
            step_resources[id] = resource
        end
    end

    -- Add template-set specific resources
    for id, resource in pairs(all_resources) do
        if resource.template_set and resource.template_set == template_set then
            step_resources[id] = resource
        end
    end

    -- Add step-specific resources from the resources array
    if entry.data.resources and #entry.data.resources > 0 then
        for _, resource_id in ipairs(entry.data.resources) do
            if all_resources[resource_id] then
                step_resources[resource_id] = all_resources[resource_id]
            end
        end
    end

    -- Group resources by type for template rendering
    local grouped_resources = group_resources_by_type(step_resources)

    return {
        id = entry.id,
        name = entry.meta.name,
        title = entry.meta.title or entry.meta.name,
        description = entry.meta.description or "",
        order = entry.meta.order or 9999,
        optional = entry.meta.optional or false,
        tutorial = entry.meta.tutorial or false,
        template_set = template_set,
        template_name = entry.meta.name,
        resources = grouped_resources
    }
end

-- Check if user can access step
function onboard_registry.can_access(step)
    -- For now, all authenticated users can access onboarding steps
    local actor = security.actor()
    return actor ~= nil
end

return onboard_registry