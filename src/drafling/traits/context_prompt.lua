local ctx = require("ctx")
local security = require("security")
local doc_repo = require("doc_repo")
local template_registry = require("template_registry")

local function generate_project_context()
    local project_id = ctx.get("project_id")
    if not project_id then
        return ""
    end

    local actor = security.actor()
    if not actor then
        return ""
    end

    local user_id = actor:id()
    local project, err = doc_repo.get(project_id, user_id)
    if err or not project then
        return ""
    end

    -- Build dynamic prompt parts
    local prompt_parts = {
        "## Current Project Context",
        "Working on: '" .. (project.title or "Untitled Project") .. "' (" .. (project.status or "active") .. ")",
        "Project ID: " .. project_id
    }

    -- Add template information
    local template_id = project.project_type
    if project.metadata and project.metadata.template_id then
        template_id = project.metadata.template_id
    end

    if template_id and template_id ~= "" then
        local template_data, template_err = template_registry.get_template(template_id)
        if not template_err and template_data and template_data.template and template_data.template.categories then
            table.insert(prompt_parts, "\n### Available Categories:")

            for _, cat_config in ipairs(template_data.template.categories) do
                local cat_line = "- " .. (cat_config.display_name or cat_config.name) .. ": "

                if cat_config.entry_types then
                    local entry_details = {}
                    for _, entry_type in ipairs(cat_config.entry_types) do
                        local entry_config = template_data.template.entry_types and
                            template_data.template.entry_types[entry_type]
                        if entry_config then
                            local entry_name = entry_config.display_name or entry_type
                            if entry_config.statuses then
                                local status_names = {}
                                for _, status in ipairs(entry_config.statuses) do
                                    table.insert(status_names, status.display_name or status.value)
                                end
                                entry_name = entry_name .. " [" .. table.concat(status_names, ", ") .. "]"
                            end
                            table.insert(entry_details, entry_name)
                        else
                            table.insert(entry_details, entry_type)
                        end
                    end
                    cat_line = cat_line .. table.concat(entry_details, "; ")
                end

                table.insert(prompt_parts, cat_line)
            end

            table.insert(prompt_parts,
                "\nYou must follow these category and entry type constraints. Use ViewProject to see current content.")
        end
    end

    return table.concat(prompt_parts, "\n")
end

return { handle = generate_project_context }
