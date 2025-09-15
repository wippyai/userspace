local ctx = require("ctx")
local json = require("json")
local doc_reader = require("doc_reader")
local template_registry = require("template_registry")
local security = require("security")
local template_helper = require("template_helper")

local function format_project(project, template)
    local builder = {}

    -- Project header
    builder[#builder + 1] = "# " .. (project.title or "Untitled Project")
    builder[#builder + 1] = "\n\n**Status:** " .. (project.status or "Draft")
    builder[#builder + 1] = "\n**Updated:** " .. (project.updated_at or "Unknown")
    builder[#builder + 1] = "\n\n"

    -- Group entries by category efficiently
    local entries_by_category = {}
    for _, entry in ipairs(project.entries or {}) do
        local cat_id = entry.category_id
        if not entries_by_category[cat_id] then
            entries_by_category[cat_id] = {}
        end
        entries_by_category[cat_id][#entries_by_category[cat_id] + 1] = entry
    end

    -- Process each category
    for _, category in ipairs(project.categories or {}) do
        local category_entries = entries_by_category[category.category_id] or {}

        builder[#builder + 1] = "## " .. (category.display_name or category.name) .. "\n\n"

        if #category_entries == 0 then
            builder[#builder + 1] = "*No entries*\n\n"
        else
            -- Sort entries by updated_at (newest first)
            table.sort(category_entries, function(a, b)
                return (a.updated_at or "") > (b.updated_at or "")
            end)

            for _, entry in ipairs(category_entries) do
                local entry_title = entry.title and entry.title ~= "" and entry.title or template_helper.get_entry_type_display_name(entry.type, template)

                builder[#builder + 1] = "### " .. entry_title .. "\n\n"
                builder[#builder + 1] = "**Type:** " .. template_helper.get_entry_type_display_name(entry.type, template)
                builder[#builder + 1] = " | **Status:** " .. template_helper.get_status_display_name(entry.status, entry.type, template)
                builder[#builder + 1] = " | **ID:** " .. entry.entry_id .. "\n\n"

                if entry.content and entry.content ~= "" then
                    builder[#builder + 1] = entry.content
                else
                    builder[#builder + 1] = "*No content*"
                end
                builder[#builder + 1] = "\n\n---\n\n"
            end
        end
    end

    return table.concat(builder)
end

local function handle(args)
    args = args or {}

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

    local template = nil
    local template_id = project_basic.project_type
    if project_basic.metadata and project_basic.metadata.template_id then
        template_id = project_basic.metadata.template_id
    end

    if template_id and template_id ~= "" then
        local template_data, _ = template_registry.get_template(template_id)
        template = template_data
    end

    -- Map display names to internal values using helper
    local internal_categories = template_helper.map_categories_display_to_internal(args.categories, template)
    local internal_entry_types = template_helper.map_entry_types_display_to_internal(args.entry_types, template)
    local internal_statuses = template_helper.map_statuses_display_to_internal(args.statuses, template)

    -- Now load project with proper internal filters
    reader = reader:with_projects(project_id):include_categories():include_entries()

    -- Apply category filter using internal names
    if #internal_categories > 0 then
        reader = reader:with_categories(unpack(internal_categories))
    end

    local project, project_err = reader:one()
    if project_err then
        return "Error loading project: " .. project_err
    end

    if not project then
        return "Error: Project not found or access denied"
    end

    -- Apply entry-level filters using internal values
    if #internal_entry_types > 0 then
        local filtered_entries = {}
        for _, entry in ipairs(project.entries or {}) do
            for _, filter_type in ipairs(internal_entry_types) do
                if entry.type == filter_type then
                    filtered_entries[#filtered_entries + 1] = entry
                    break
                end
            end
        end
        project.entries = filtered_entries
    end

    if #internal_statuses > 0 then
        local filtered_entries = {}
        for _, entry in ipairs(project.entries or {}) do
            for _, filter_status in ipairs(internal_statuses) do
                if entry.status == filter_status then
                    filtered_entries[#filtered_entries + 1] = entry
                    break
                end
            end
        end
        project.entries = filtered_entries
    end

    return format_project(project, template)
end

return { handle = handle }