local ctx = require("ctx")
local json = require("json")
local doc_reader = require("doc_reader")
local template_registry = require("template_registry")
local security = require("security")

local function format_structure_markdown(template_data, include_internal)
    local builder = {}

    builder[#builder + 1] = "# Project Template Structure\n"

    if template_data.meta then
        builder[#builder + 1] = "**Template:** " .. (template_data.meta.name or "Unknown")
        if template_data.meta.description then
            builder[#builder + 1] = "\n**Description:** " .. template_data.meta.description
        end
        builder[#builder + 1] = "\n\n"
    end

    if not template_data.template or not template_data.template.categories then
        builder[#builder + 1] = "*No template structure available*\n"
        return table.concat(builder)
    end

    builder[#builder + 1] = "## Available Categories\n\n"

    -- Process each category
    for _, category in ipairs(template_data.template.categories) do
        local cat_name = category.display_name or category.name
        builder[#builder + 1] = "### " .. cat_name

        if include_internal and category.name and category.name ~= cat_name then
            builder[#builder + 1] = " (" .. category.name .. ")"
        end

        builder[#builder + 1] = "\n\n"

        if category.entry_types and #category.entry_types > 0 then
            builder[#builder + 1] = "**Allowed Entry Types:**\n\n"

            for _, entry_type in ipairs(category.entry_types) do
                local entry_config = template_data.template.entry_types and
                    template_data.template.entry_types[entry_type]

                if entry_config then
                    local entry_name = entry_config.display_name or entry_type
                    builder[#builder + 1] = "- **" .. entry_name .. "**"

                    if include_internal and entry_type ~= entry_name then
                        builder[#builder + 1] = " (" .. entry_type .. ")"
                    end

                    builder[#builder + 1] = "\n"

                    -- Add entry details
                    if entry_config.color then
                        builder[#builder + 1] = "  - Color: " .. entry_config.color .. "\n"
                    end

                    if entry_config.content_type then
                        builder[#builder + 1] = "  - Content Type: " .. entry_config.content_type .. "\n"
                    end

                    if entry_config.default_status then
                        builder[#builder + 1] = "  - Default Status: " .. entry_config.default_status .. "\n"
                    end

                    -- Add available statuses
                    if entry_config.statuses and #entry_config.statuses > 0 then
                        builder[#builder + 1] = "  - Available Statuses: "
                        local status_names = {}
                        for _, status in ipairs(entry_config.statuses) do
                            local status_display = status.display_name or status.value
                            if include_internal and status.value and status.value ~= status_display then
                                status_display = status_display .. " (" .. status.value .. ")"
                            end
                            table.insert(status_names, status_display)
                        end
                        builder[#builder + 1] = table.concat(status_names, ", ") .. "\n"
                    end

                    builder[#builder + 1] = "\n"
                else
                    builder[#builder + 1] = "- " .. entry_type .. " *(no configuration found)*\n\n"
                end
            end
        else
            builder[#builder + 1] = "*No entry types configured*\n\n"
        end
    end

    return table.concat(builder)
end

local function format_structure_json(template_data, include_internal)
    local structure = {
        template_info = {},
        categories = {}
    }

    if template_data.meta then
        structure.template_info = {
            name = template_data.meta.name,
            description = template_data.meta.description,
            comment = template_data.meta.comment
        }
    end

    if template_data.template and template_data.template.categories then
        for _, category in ipairs(template_data.template.categories) do
            local cat_info = {
                display_name = category.display_name or category.name,
                entry_types = {}
            }

            if include_internal then
                cat_info.internal_name = category.name
            end

            if category.entry_types then
                for _, entry_type in ipairs(category.entry_types) do
                    local entry_config = template_data.template.entry_types and
                        template_data.template.entry_types[entry_type]

                    local entry_info = {
                        display_name = entry_config and entry_config.display_name or entry_type
                    }

                    if include_internal then
                        entry_info.internal_name = entry_type
                    end

                    if entry_config then
                        entry_info.color = entry_config.color
                        entry_info.content_type = entry_config.content_type
                        entry_info.default_status = entry_config.default_status

                        if entry_config.statuses then
                            entry_info.statuses = {}
                            for _, status in ipairs(entry_config.statuses) do
                                local status_info = {
                                    display_name = status.display_name or status.value
                                }
                                if include_internal then
                                    status_info.internal_value = status.value
                                end
                                if status.color then
                                    status_info.color = status.color
                                end
                                table.insert(entry_info.statuses, status_info)
                            end
                        end
                    end

                    table.insert(cat_info.entry_types, entry_info)
                end
            end

            table.insert(structure.categories, cat_info)
        end
    end

    return json.encode(structure)
end

local function handle(args)
    args = args or {}
    local format = args.format or "markdown"
    local include_internal = args.include_internal or false

    local project_id = ctx.get("project_id")
    if not project_id then
        return "Error: No project context available"
    end

    local actor = security.actor()
    if not actor then
        return "Error: No user context available"
    end
    local user_id = actor:id()

    local reader, reader_err = doc_reader.with_user(user_id)
    if reader_err then
        return "Error creating reader: " .. reader_err
    end

    -- Get project to determine template
    local project_basic, project_err = reader:with_projects(project_id):one()
    if project_err then
        return "Error loading project: " .. project_err
    end

    if not project_basic then
        return "Error: Project not found or access denied"
    end

    local template_id = project_basic.project_type
    if project_basic.metadata and project_basic.metadata.template_id then
        template_id = project_basic.metadata.template_id
    end

    if not template_id or template_id == "" then
        return "Error: No template associated with this project"
    end

    local template_data, template_err = template_registry.get_template(template_id)
    if template_err then
        return "Error loading template: " .. template_err
    end

    if not template_data then
        return "Error: Template not found"
    end

    if format == "json" then
        return format_structure_json(template_data, include_internal)
    else
        return format_structure_markdown(template_data, include_internal)
    end
end

return { handle = handle }