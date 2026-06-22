local http = require("http")
local json = require("json")
local security = require("security")
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

    local options = {}

    local project_type = req:query("project_type")
    if project_type and project_type ~= "" then
        options.project_type = project_type
    end

    local status = req:query("status")
    if status and status ~= "" then
        options.status = status
    end

    local order_by = req:query("order_by")
    if order_by and order_by ~= "" then
        options.order_by = order_by
    end

    local limit = req:query("limit")
    if limit and limit ~= "" then
        local num_limit = tonumber(limit)
        if num_limit and num_limit > 0 then
            options.limit = num_limit
        end
    end

    local offset = req:query("offset")
    if offset and offset ~= "" then
        local num_offset = tonumber(offset)
        if num_offset and num_offset >= 0 then
            options.offset = num_offset
        end
    end

    local projects, err = doc_repo.list_by_user(user_id, options)
    if err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to list projects", err)
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        count = #projects,
        projects = projects
    })
end

return {
    handler = handler
}