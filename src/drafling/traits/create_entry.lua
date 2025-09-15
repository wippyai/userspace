local ctx = require("ctx")
local json = require("json")
local security = require("security")
local writer = require("writer")
local template_registry = require("template_registry")
local doc_reader = require("doc_reader")
local template_helper = require("template_helper")

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

    -- Validate required fields
    if not args.category or args.category == "" then
        return "Error: Category is required"
    end

    if not args.entry_type or args.entry_type == "" then
        return "Error: Entry type is required"
    end

    if not args.content then
        args.content = "" -- Allow empty content
    end

    -- Load project and template for validation
    local reader, reader_err = doc_reader.with_user(user_id)
    if reader_err then
        return "Error creating reader: " .. reader_err
    end

    local project, project_err = reader:with_projects(project_id):include_categories():one()
    if project_err then
        return "Error loading project: " .. project_err
    end

    if not project then
        return "Error: Project not found or access denied"
    end

    -- Load template
    local template = nil
    local template_id = project.project_type
    if project.metadata and project.metadata.template_id then
        template_id = project.metadata.template_id
    end

    if template_id and template_id ~= "" then
        local template_data, _ = template_registry.get_template(template_id)
        template = template_data
    end

    -- Map display names to internal values
    local internal_category = template_helper.map_category_display_to_internal(args.category, template)
    local internal_entry_type = template_helper.map_entry_type_display_to_internal(args.entry_type, template)

    -- Find the category ID
    local category_id = template_helper.find_category_id_by_name(internal_category, project)
    if not category_id then
        return "Error: Category '" .. args.category .. "' not found in project"
    end

    -- Validate that entry type is allowed in this category
    if not template_helper.validate_category_allows_entry_type(internal_category, internal_entry_type, template) then
        return "Error: Entry type '" .. args.entry_type .. "' is not allowed in category '" .. args.category .. "'"
    end

    -- Determine status
    local status = args.status
    if status then
        status = template_helper.map_status_display_to_internal(status, internal_entry_type, template)
    else
        status = template_helper.get_default_status_for_entry_type(internal_entry_type, template)
    end

    -- Determine content type
    local content_type = template_helper.get_default_content_type_for_entry_type(internal_entry_type, template)

    -- Create the entry
    local batch, batch_err = writer.for_project(user_id, project_id)
    if batch_err then
        return "Error creating batch: " .. batch_err
    end

    batch, batch_err = batch:create_entry(
        category_id,
        internal_entry_type,
        args.content,
        content_type,
        args.title or "",
        status,
        {} -- No metadata for agent
    )

    if batch_err then
        return "Error adding create entry command: " .. batch_err
    end

    local result, exec_err = batch:execute()
    if exec_err then
        return "Error executing create entry: " .. exec_err
    end

    local entry_result = result.results[1]

    return string.format("Created %s '%s' in %s\nEntry ID: %s",
        args.entry_type,
        args.title or "Untitled",
        args.category,
        entry_result.entry_id
    )
end

return { handle = handle }