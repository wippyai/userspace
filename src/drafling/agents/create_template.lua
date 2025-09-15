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

    if not params.name or params.name == "" then
        response.error = "Template name is required"
        return response
    end

    if not params.description or params.description == "" then
        response.error = "Template description is required"
        return response
    end

    if not params.categories or type(params.categories) ~= "table" or #params.categories == 0 then
        response.error = "At least one category is required"
        return response
    end

    if not params.entry_types or type(params.entry_types) ~= "table" then
        response.error = "Entry types definition is required"
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

    local existing_template, _ = registry.get(template_id)
    if existing_template then
        response.error = "Template with ID '" .. template_id .. "' already exists"
        return response
    end

    for i, category in ipairs(params.categories) do
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

        for _, entry_type in ipairs(category.entry_types) do
            if not params.entry_types[entry_type] then
                response.error = "Category " .. i .. " references undefined entry type: " .. entry_type
                return response
            end
        end

        if not category.icon then
            category.icon = "tabler:folder"
        end
    end

    for entry_type_name, entry_type_def in pairs(params.entry_types) do
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

        if entry_type_def.statuses then
            if type(entry_type_def.statuses) ~= "table" then
                response.error = "Entry type '" .. entry_type_name .. "' statuses must be an array"
                return response
            end

            for j, status in ipairs(entry_type_def.statuses) do
                if not status.value or not status.display_name then
                    response.error = "Entry type '" .. entry_type_name .. "' status " .. j .. " must have value and display_name"
                    return response
                end
            end
        else
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

    local template_entry = {
        id = template_id,
        kind = "registry.entry",
        meta = {
            type = "drafling.template",
            name = params.name,
            description = params.description,
            icon = params.icon or "tabler:folder",
            tags = params.tags or {},
            agent_id = params.agent_id
        },
        data = {
            template = {
                categories = params.categories,
                entry_types = params.entry_types
            }
        }
    }

    local changeset = {
        {
            kind = "entry.create",
            entry = template_entry
        }
    }

    local result, submit_err = governance_client.request_changes(changeset)
    if not result then
        response.error = "Failed to create template: " .. (submit_err or "unknown error")
        return response
    end

    response.success = true
    response.template_id = template_id
    response.name = params.name
    response.categories_count = #params.categories
    response.entry_types_count = 0
    for _ in pairs(params.entry_types) do
        response.entry_types_count = response.entry_types_count + 1
    end
    response.version = result.version

    return response
end

return { handler = handler }