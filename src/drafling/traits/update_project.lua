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

    -- Check if we have any updates to apply
    if not args.title and not args.description and not args.status then
        return "Error: No updates provided. Specify title, description, or status"
    end

    -- Build updates object
    local updates = {}
    local update_description = {}

    if args.title then
        updates.title = args.title
        table.insert(update_description, "title to '" .. args.title .. "'")
    end

    if args.status then
        updates.status = args.status
        table.insert(update_description, "status to '" .. args.status .. "'")
    end

    if args.description then
        updates.metadata = {
            comment = args.description
        }
        table.insert(update_description, "description")
    end

    -- Execute the update
    local batch, batch_err = writer.for_project(user_id, project_id)
    if batch_err then
        return "Error creating batch: " .. batch_err
    end

    batch, batch_err = batch:update_project(updates)
    if batch_err then
        return "Error adding update project command: " .. batch_err
    end

    local result, exec_err = batch:execute()
    if exec_err then
        return "Error executing update project: " .. exec_err
    end

    local project_result = result.results[1]

    if not project_result.changes_made then
        return "No changes were made to the project"
    end

    return "Updated project: " .. table.concat(update_description, ", ")
end

return { handle = handle }