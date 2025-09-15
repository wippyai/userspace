local json = require("json")
local security = require("security")
local writer = require("writer")

local function handler(params)
    local response = {
        success = false,
        project_id = params.project_id,
        error = nil
    }

    if not params.project_id or params.project_id == "" then
        response.error = "Project ID is required"
        return response
    end

    local actor = security.actor()
    if not actor then
        response.error = "Authentication required"
        return response
    end

    local user_id = actor:id()

    local updates = {}

    if params.title then
        updates.title = params.title
    end

    if params.status then
        updates.status = params.status
    end

    if params.description ~= nil then
        updates.metadata = {
            comment = params.description
        }
    end

    if next(updates) == nil then
        response.error = "No valid fields to update"
        return response
    end

    local batch, batch_err = writer.for_project(user_id, params.project_id)
    if batch_err then
        response.error = "Failed to create batch: " .. batch_err
        return response
    end

    batch, batch_err = batch:update_project(updates)
    if batch_err then
        response.error = "Failed to add update command: " .. batch_err
        return response
    end

    local result, exec_err = batch:execute()
    if exec_err then
        response.error = "Failed to execute update: " .. exec_err
        return response
    end

    response.success = true
    response.changes_made = result.changes_made
    response.updated_fields = updates
    return response
end

return { handler = handler }