local http = require("http")
local json = require("json")
local security = require("security")
local history_repo = require("history_repo")
local doc_repo = require("doc_repo")
local api_error = require("api_error")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    local user_id = actor:id()
    local project_id = req:param("project_id")

    if not project_id or project_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Project ID is required"
        })
        return
    end

    -- Verify project exists and user has access
    local project, project_err = doc_repo.get(project_id, user_id)
    if project_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to verify project access", project_err)
        return
    end

    if not project then
        res:set_status(http.STATUS.NOT_FOUND)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Project not found or access denied"
        })
        return
    end

    -- Parse query parameters for filtering
    local options = {}

    if req:query("limit") then
        options.limit = tonumber(req:query("limit"))
    end

    if req:query("offset") then
        options.offset = tonumber(req:query("offset"))
    end

    if req:query("operation_type") then
        options.operation_type = req:query("operation_type")
    end

    if req:query("order") then
        options.order = req:query("order")
    end

    -- Get project history
    local history, history_err = history_repo.get_project_history(project_id, options)
    if history_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get project history", history_err)
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        history = history or {}
    })
end

return {
    handler = handler
}