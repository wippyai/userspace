local http = require("http")
local json = require("json")
local security = require("security")
local writer = require("writer")

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
    local entry_id = req:param("entry_id")

    if not project_id or project_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Project ID is required"
        })
        return
    end

    if not entry_id or entry_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Entry ID is required"
        })
        return
    end

    local body, err = req:body()
    if err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to read request body: " .. err
        })
        return
    end

    local data, json_err = json.decode(body)
    if json_err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Invalid JSON: " .. json_err
        })
        return
    end

    local updates = {}
    if data.title ~= nil then updates.title = data.title end
    if data.content ~= nil then updates.content = data.content end
    if data.status ~= nil then updates.status = data.status end
    if data.content_type ~= nil then updates.content_type = data.content_type end
    if data.metadata ~= nil then updates.metadata = data.metadata end

    if next(updates) == nil then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "No fields provided for update"
        })
        return
    end

    local batch, batch_err = writer.for_project(user_id, project_id)
    if batch_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to create batch: " .. batch_err
        })
        return
    end

    batch, batch_err = batch:update_entry(entry_id, updates)
    if batch_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to add update entry command: " .. batch_err
        })
        return
    end

    local result, exec_err = batch:execute()
    if exec_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to execute commands: " .. exec_err
        })
        return
    end

    local entry_result = result.results[1]
    res:set_status(http.STATUS.CREATED)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        entry_id = entry_id,
        history_id = entry_result.history_id,
        changes_made = entry_result.changes_made
    })
end

return {
    handler = handler
}