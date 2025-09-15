local ctx = require("ctx")
local json = require("json")
local security = require("security")
local writer = require("writer")

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

    -- Execute the deletion
    local batch, batch_err = writer.for_project(user_id, project_id)
    if batch_err then
        return "Error creating batch: " .. batch_err
    end

    batch, batch_err = batch:delete_entry(args.entry_id)
    if batch_err then
        return "Error adding delete entry command: " .. batch_err
    end

    local result, exec_err = batch:execute()
    if exec_err then
        return "Error executing delete entry: " .. exec_err
    end

    local entry_result = result.results[1]

    if not entry_result.changes_made then
        return "Entry not found or already deleted: " .. args.entry_id
    end

    return "Deleted entry: " .. args.entry_id
end

return { handle = handle }