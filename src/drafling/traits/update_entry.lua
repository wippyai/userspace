local ctx = require("ctx")
local json = require("json")
local security = require("security")
local writer = require("writer")
local template_registry = require("template_registry")
local doc_reader = require("doc_reader")
local template_helper = require("template_helper")

-- Simple string replacement function
local function string_replace(text, find, replace)
    if not text or not find or find == "" then
        return text
    end

    -- Escape special pattern characters in find string
    local escaped_find = find:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")

    return text:gsub(escaped_find, replace or "")
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

    -- Validate required fields
    if not args.entry_id or args.entry_id == "" then
        return "Error: Entry ID is required"
    end

    -- Check if we have any updates to apply
    if not args.title and not args.content and not args.status and not args.content_type and not args.text_replace then
        return "Error: No updates provided. Specify title, content, status, content_type, or text_replace"
    end

    -- Load project and entry for validation
    local reader, reader_err = doc_reader.with_user(user_id)
    if reader_err then
        return "Error creating reader: " .. reader_err
    end

    local project, project_err = reader:with_projects(project_id):include_categories():include_entries():one()
    if project_err then
        return "Error loading project: " .. project_err
    end

    if not project then
        return "Error: Project not found or access denied"
    end

    -- Find the entry
    local entry = template_helper.get_entry_by_id(args.entry_id, project)
    if not entry then
        return "Error: Entry not found with ID: " .. args.entry_id
    end

    -- Load template for status validation
    local template = nil
    local template_id = project.project_type
    if project.metadata and project.metadata.template_id then
        template_id = project.metadata.template_id
    end

    if template_id and template_id ~= "" then
        local template_data, _ = template_registry.get_template(template_id)
        template = template_data
    end

    -- Build updates object
    local updates = {}
    local update_description = {}

    if args.title then
        updates.title = args.title
        table.insert(update_description, "title")
    end

    if args.content then
        updates.content = args.content
        table.insert(update_description, "content")
    elseif args.text_replace then
        -- Apply text replacement to existing content
        if not entry.content then
            return "Error: Cannot apply text replacement - entry has no content"
        end

        local new_content = string_replace(entry.content, args.text_replace.find, args.text_replace.replace)
        if new_content == entry.content then
            return "No changes made - text '" .. args.text_replace.find .. "' not found in content"
        end

        updates.content = new_content
        table.insert(update_description, "content (replaced '" .. args.text_replace.find .. "' with '" .. args.text_replace.replace .. "')")
    end

    if args.status then
        local internal_status = template_helper.map_status_display_to_internal(args.status, entry.type, template)
        updates.status = internal_status
        table.insert(update_description, "status to '" .. args.status .. "'")
    end

    if args.content_type then
        updates.content_type = args.content_type
        table.insert(update_description, "content type to '" .. args.content_type .. "'")
    end

    -- Execute the update
    local batch, batch_err = writer.for_project(user_id, project_id)
    if batch_err then
        return "Error creating batch: " .. batch_err
    end

    batch, batch_err = batch:update_entry(args.entry_id, updates)
    if batch_err then
        return "Error adding update entry command: " .. batch_err
    end

    local result, exec_err = batch:execute()
    if exec_err then
        return "Error executing update entry: " .. exec_err
    end

    local entry_result = result.results[1]

    if not entry_result.changes_made then
        return "No changes were made to the entry"
    end

    return string.format("Updated %s: %s",
        entry.title or "entry",
        table.concat(update_description, ", ")
    )
end

return { handle = handle }