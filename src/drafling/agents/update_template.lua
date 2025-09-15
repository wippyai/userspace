local json = require("json")
local registry = require("registry")
local governance_client = require("governance_client")

local function handler(params)
    local response = {
        success = false,
        template_id = params.template_id,
        error = nil
    }

    if not params.template_id or params.template_id == "" then
        response.error = "Template ID is required"
        return response
    end

    local template_id = params.template_id
    if not template_id:match(":") then
        if params.topic then
            template_id = "app.drafling." .. params.topic .. ":" .. template_id
        else
            template_id = "app.drafling.custom:" .. template_id
        end
    end

    if not template_id:match("^[a-z0-9_]+%.[a-z0-9_]+%.[a-z0-9_]+:[a-z0-9_]+$") then
        response.error = "Template ID must be in format namespace:name (e.g., 'app.drafling.web_research:my_template')"
        return response
    end

    local existing_template, get_err = registry.get(template_id)
    if not existing_template then
        response.error = "Template not found: " .. template_id
        return response
    end

    if not existing_template.meta or existing_template.meta.type ~= "drafling.template" then
        response.error = "Entry is not a drafling template: " .. template_id
        return response
    end

    local updated_meta = {}
    for k, v in pairs(existing_template.meta) do
        updated_meta[k] = v
    end

    local updated_template_data = {}
    if existing_template.data and existing_template.data.template then
        updated_template_data.categories = existing_template.data.template.categories or {}
        updated_template_data.entry_types = existing_template.data.template.entry_types or {}
    elseif existing_template.template then
        updated_template_data.categories = existing_template.template.categories or {}
        updated_template_data.entry_types = existing_template.template.entry_types or {}
    end

    if params.name then
        updated_meta.name = params.name
    end

    if params.description then
        updated_meta.description = params.description
    end

    if params.icon then
        updated_meta.icon = params.icon
    end

    if params.tags then
        updated_meta.tags = params.tags
    end

    if params.agent_id then
        updated_meta.agent_id = params.agent_id
    end

    if params.add_categories then
        for _, category in ipairs(params.add_categories) do
            if not category.name or not category.name:match("^[a-z0-9_]+$") then
                response.error = "Category name must be lowercase with underscores only"
                return response
            end

            if not category.display_name or category.display_name == "" then
                response.error = "Category display_name is required"
                return response
            end

            if not category.entry_types or type(category.entry_types) ~= "table" or #category.entry_types == 0 then
                response.error = "Category must have at least one entry type"
                return response
            end

            if not category.icon then
                category.icon = "tabler:folder"
            end

            local exists = false
            for _, existing_cat in ipairs(updated_template_data.categories) do
                if existing_cat.name == category.name then
                    exists = true
                    break
                end
            end

            if not exists then
                table.insert(updated_template_data.categories, category)
            end
        end
    end

    if params.remove_categories then
        local new_categories = {}
        for _, existing_cat in ipairs(updated_template_data.categories) do
            local should_remove = false
            for _, remove_name in ipairs(params.remove_categories) do
                if existing_cat.name == remove_name then
                    should_remove = true
                    break
                end
            end
            if not should_remove then
                table.insert(new_categories, existing_cat)
            end
        end
        updated_template_data.categories = new_categories
    end

    if params.set_categories then
        for i, category in ipairs(params.set_categories) do
            if not category.name or not category.name:match("^[a-z0-9_]+$") then
                response.error = "Category " .. i .. " name must be lowercase with underscores only"
                return response
            end

            if not category.display_name or category.display_name == "" then
                response.error = "Category " .. i .. " display_name is required"
                return response
            end

            if not category.entry_types or type(category.entry_types) ~= "table" or #category.entry_types == 0 then
                response.error = "Category " .. i .. " must have at least one entry type"
                return response
            end

            if not category.icon then
                category.icon = "tabler:folder"
            end
        end
        updated_template_data.categories = params.set_categories
    end

    if params.add_entry_types then
        for entry_type_name, entry_type_def in pairs(params.add_entry_types) do
            if not entry_type_name:match("^[a-z0-9_]+$") then
                response.error = "Entry type '" .. entry_type_name .. "' name must be lowercase with underscores only"
                return response
            end

            if not entry_type_def.display_name or entry_type_def.display_name == "" then
                response.error = "Entry type '" .. entry_type_name .. "' display_name is required"
                return response
            end

            if not entry_type_def.content_type then
                entry_type_def.content_type = "text/markdown"
            end

            if not entry_type_def.icon then
                entry_type_def.icon = "tabler:file-text"
            end

            if not entry_type_def.color then
                entry_type_def.color = "blue"
            end

            if not entry_type_def.statuses then
                entry_type_def.statuses = {
                    { value = "draft", display_name = "Draft", color = "gray" },
                    { value = "in_progress", display_name = "In Progress", color = "blue" },
                    { value = "complete", display_name = "Complete", color = "green" }
                }
            end

            if not entry_type_def.default_status then
                entry_type_def.default_status = "draft"
            end

            updated_template_data.entry_types[entry_type_name] = entry_type_def
        end
    end

    if params.remove_entry_types then
        for _, remove_name in ipairs(params.remove_entry_types) do
            updated_template_data.entry_types[remove_name] = nil
        end
    end

    if params.set_entry_types then
        for entry_type_name, entry_type_def in pairs(params.set_entry_types) do
            if not entry_type_name:match("^[a-z0-9_]+$") then
                response.error = "Entry type '" .. entry_type_name .. "' name must be lowercase with underscores only"
                return response
            end

            if not entry_type_def.display_name or entry_type_def.display_name == "" then
                response.error = "Entry type '" .. entry_type_name .. "' display_name is required"
                return response
            end

            if not entry_type_def.content_type then
                entry_type_def.content_type = "text/markdown"
            end

            if not entry_type_def.icon then
                entry_type_def.icon = "tabler:file-text"
            end

            if not entry_type_def.color then
                entry_type_def.color = "blue"
            end

            if not entry_type_def.statuses then
                entry_type_def.statuses = {
                    { value = "draft", display_name = "Draft", color = "gray" },
                    { value = "in_progress", display_name = "In Progress", color = "blue" },
                    { value = "complete", display_name = "Complete", color = "green" }
                }
            end

            if not entry_type_def.default_status then
                entry_type_def.default_status = "draft"
            end
        end
        updated_template_data.entry_types = params.set_entry_types
    end

    for i, category in ipairs(updated_template_data.categories) do
        for _, entry_type in ipairs(category.entry_types) do
            if not updated_template_data.entry_types[entry_type] then
                response.error = "Category " .. i .. " references undefined entry type: " .. entry_type
                return response
            end
        end
    end

    local updated_entry = {
        id = template_id,
        kind = "registry.entry",
        meta = updated_meta,
        data = {
            template = updated_template_data
        }
    }

    local changeset = {
        {
            kind = "entry.update",
            entry = updated_entry
        }
    }

    local result, submit_err = governance_client.request_changes(changeset)
    if not result then
        response.error = "Failed to update template: " .. (submit_err or "unknown error")
        return response
    end

    response.success = true
    response.template_id = template_id
    response.name = updated_meta.name
    response.categories_count = #updated_template_data.categories
    response.entry_types_count = 0
    for _ in pairs(updated_template_data.entry_types) do
        response.entry_types_count = response.entry_types_count + 1
    end
    response.version = result.version

    return response
end

return { handler = handler }