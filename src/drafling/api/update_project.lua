local http = require("http")
local json = require("json")
local security = require("security")
local writer = require("writer")
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

    local project_id = req:param("id")
    if not project_id or project_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Project ID is required"
        })
        return
    end

    local body, err = req:body()
    if err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.BAD_REQUEST, "Failed to read request body", err)
        return
    end

    local data, json_err = json.decode(body)
    if json_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.BAD_REQUEST, "Invalid JSON", json_err)
        return
    end

    local updates = {}

    if data.title then
        updates.title = data.title
    end

    if data.status then
        updates.status = data.status
    end

    if data.description ~= nil then
        updates.metadata = {
            comment = data.description
        }
    end

    if next(updates) == nil then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "No valid fields to update"
        })
        return
    end

    local batch, batch_err = writer.for_project(user_id, project_id)
    if batch_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to create batch", batch_err)
        return
    end

    batch, batch_err = batch:update_project(updates)
    if batch_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to add update command", batch_err)
        return
    end

    local result, exec_err = batch:execute()
    if exec_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to execute update", exec_err)
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        project_id = project_id,
        changes_made = result.changes_made,
        updated_fields = updates
    })
end

return {
    handler = handler
}