local template_helper = {}

-- ============================================================================
-- DISPLAY NAME TO INTERNAL MAPPING
-- ============================================================================

function template_helper.map_category_display_to_internal(display_name, template)
    if not display_name or not template or not template.template or not template.template.categories then
        return display_name -- Fallback to original name
    end

    for _, cat_config in ipairs(template.template.categories) do
        local cat_display = cat_config.display_name or cat_config.name
        if cat_display == display_name or cat_config.name == display_name then
            return cat_config.name
        end
    end

    return display_name -- Fallback if not found
end

function template_helper.map_entry_type_display_to_internal(display_name, template)
    if not display_name or not template or not template.template or not template.template.entry_types then
        return display_name -- Fallback to original name
    end

    for entry_type, entry_config in pairs(template.template.entry_types) do
        local type_display = entry_config.display_name or entry_type
        if type_display == display_name or entry_type == display_name then
            return entry_type
        end
    end

    return display_name -- Fallback if not found
end

function template_helper.map_status_display_to_internal(display_name, entry_type, template)
    if not display_name or not template or not template.template or not template.template.entry_types then
        return display_name -- Fallback to original name
    end

    if not template.template.entry_types[entry_type] or not template.template.entry_types[entry_type].statuses then
        return display_name -- Fallback if no statuses defined
    end

    for _, status_config in ipairs(template.template.entry_types[entry_type].statuses) do
        local status_display = status_config.display_name or status_config.value
        if status_display == display_name or status_config.value == display_name then
            return status_config.value
        end
    end

    return display_name -- Fallback if not found
end

-- ============================================================================
-- INTERNAL TO DISPLAY NAME MAPPING
-- ============================================================================

function template_helper.get_category_display_name(internal_name, template)
    if not template or not template.template or not template.template.categories then
        return internal_name:sub(1,1):upper() .. internal_name:sub(2) -- Basic capitalization
    end

    for _, cat_config in ipairs(template.template.categories) do
        if cat_config.name == internal_name then
            return cat_config.display_name or internal_name
        end
    end

    return internal_name:sub(1,1):upper() .. internal_name:sub(2) -- Fallback
end

function template_helper.get_entry_type_display_name(internal_type, template)
    if template and template.template and template.template.entry_types and template.template.entry_types[internal_type] then
        return template.template.entry_types[internal_type].display_name or internal_type
    end
    return internal_type:sub(1,1):upper() .. internal_type:sub(2)
end

function template_helper.get_status_display_name(internal_status, entry_type, template)
    if template and template.template and template.template.entry_types and template.template.entry_types[entry_type] then
        local statuses = template.template.entry_types[entry_type].statuses or {}
        for _, status_config in ipairs(statuses) do
            if status_config.value == internal_status then
                return status_config.display_name or internal_status
            end
        end
    end
    return internal_status:sub(1,1):upper() .. internal_status:sub(2)
end

-- ============================================================================
-- BATCH MAPPING FOR FILTERS
-- ============================================================================

function template_helper.map_categories_display_to_internal(display_names, template)
    if not display_names or #display_names == 0 then
        return {}
    end

    local internal_names = {}
    for _, display_name in ipairs(display_names) do
        local internal_name = template_helper.map_category_display_to_internal(display_name, template)
        internal_names[#internal_names + 1] = internal_name
    end

    return internal_names
end

function template_helper.map_entry_types_display_to_internal(display_names, template)
    if not display_names or #display_names == 0 then
        return {}
    end

    local internal_types = {}
    for _, display_name in ipairs(display_names) do
        local internal_type = template_helper.map_entry_type_display_to_internal(display_name, template)
        internal_types[#internal_types + 1] = internal_type
    end

    return internal_types
end

function template_helper.map_statuses_display_to_internal(display_names, template)
    if not display_names or #display_names == 0 then
        return {}
    end

    local internal_statuses = {}
    if template and template.template and template.template.entry_types then
        -- Search through all entry types for matching status display names
        for _, display_name in ipairs(display_names) do
            for _, entry_config in pairs(template.template.entry_types) do
                if entry_config.statuses then
                    for _, status_config in ipairs(entry_config.statuses) do
                        local status_display = status_config.display_name or status_config.value
                        if status_display == display_name or status_config.value == display_name then
                            -- Avoid duplicates
                            local already_added = false
                            for _, existing in ipairs(internal_statuses) do
                                if existing == status_config.value then
                                    already_added = true
                                    break
                                end
                            end
                            if not already_added then
                                internal_statuses[#internal_statuses + 1] = status_config.value
                            end
                            break
                        end
                    end
                end
            end
        end
    else
        -- No template, assume direct mapping
        internal_statuses = display_names
    end

    return internal_statuses
end

-- ============================================================================
-- VALIDATION FUNCTIONS
-- ============================================================================

function template_helper.validate_category_allows_entry_type(category_name, entry_type, template)
    if not template or not template.template or not template.template.categories then
        return true -- No template constraints
    end

    for _, cat_config in ipairs(template.template.categories) do
        if cat_config.name == category_name then
            if not cat_config.entry_types then
                return true -- No restrictions
            end

            for _, allowed_type in ipairs(cat_config.entry_types) do
                if allowed_type == entry_type then
                    return true
                end
            end

            return false -- Entry type not allowed in this category
        end
    end

    return true -- Category not found in template, allow by default
end

function template_helper.get_allowed_entry_types_for_category(category_name, template)
    if not template or not template.template or not template.template.categories then
        return {} -- No template constraints
    end

    for _, cat_config in ipairs(template.template.categories) do
        if cat_config.name == category_name then
            return cat_config.entry_types or {}
        end
    end

    return {} -- Category not found
end

function template_helper.get_allowed_statuses_for_entry_type(entry_type, template)
    if not template or not template.template or not template.template.entry_types then
        return {} -- No template constraints
    end

    local entry_config = template.template.entry_types[entry_type]
    if not entry_config or not entry_config.statuses then
        return {} -- No statuses defined
    end

    local statuses = {}
    for _, status_config in ipairs(entry_config.statuses) do
        statuses[#statuses + 1] = status_config.value
    end

    return statuses
end

-- ============================================================================
-- DEFAULT VALUE FUNCTIONS
-- ============================================================================

function template_helper.get_default_status_for_entry_type(entry_type, template)
    if not template or not template.template or not template.template.entry_types then
        return "draft" -- Default fallback
    end

    local entry_config = template.template.entry_types[entry_type]
    if entry_config and entry_config.default_status then
        return entry_config.default_status
    end

    return "draft" -- Default fallback
end

function template_helper.get_default_content_type_for_entry_type(entry_type, template)
    if not template or not template.template or not template.template.entry_types then
        return "text/markdown" -- Default for drafling
    end

    local entry_config = template.template.entry_types[entry_type]
    if entry_config and entry_config.content_type then
        return entry_config.content_type
    end

    return "text/markdown" -- Default for drafling
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

function template_helper.find_category_id_by_name(category_name, project)
    if not project or not project.categories then
        return nil
    end

    for _, category in ipairs(project.categories) do
        if category.name == category_name then
            return category.category_id
        end
    end

    return nil
end

function template_helper.get_entry_by_id(entry_id, project)
    if not project or not project.entries then
        return nil
    end

    for _, entry in ipairs(project.entries) do
        if entry.entry_id == entry_id then
            return entry
        end
    end

    return nil
end

return template_helper