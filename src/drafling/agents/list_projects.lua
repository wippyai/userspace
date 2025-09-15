local json = require("json")
local security = require("security")
local doc_repo = require("doc_repo")

local function handler(params)
    local response = {
        success = false,
        projects = {},
        error = nil
    }

    params = params or {}

    local actor = security.actor()
    if not actor then
        response.error = "Authentication required"
        return response
    end

    local user_id = actor:id()

    local options = {}

    if params.project_type then
        options.project_type = params.project_type
    end

    if params.status then
        options.status = params.status
    end

    if params.limit then
        options.limit = params.limit
    else
        options.limit = 20
    end

    local projects, err = doc_repo.list_by_user(user_id, options)
    if err then
        response.error = "Failed to list projects: " .. err
        return response
    end

    response.success = true
    response.projects = projects or {}
    response.count = #response.projects
    return response
end

return { handler = handler }