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

    if not data.category_id or data.category_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Category ID is required"
        })
        return
    end

    if not data.type or data.type == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Entry type is required"
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

    batch, batch_err = batch:create_entry(
        data.category_id,
        data.type,
        data.content or "",
        data.content_type or "text/plain",
        data.title or "",
        data.status or "draft",
        data.metadata or {}
    )

    if batch_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to add create entry command: " .. batch_err
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
        entry_id = entry_result.entry_id,
        history_id = entry_result.history_id
    })
end

return {
    handler = handler
}