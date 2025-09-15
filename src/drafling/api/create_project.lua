local http = require("http")
local json = require("json")
local security = require("security")
local writer = require("writer")
local template_registry = require("template_registry")

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

    if not data.title or data.title == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Project title is required"
        })
        return
    end

    if not data.template_id or data.template_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Template ID is required"
        })
        return
    end

    local template, template_err = template_registry.get_template(data.template_id)
    if template_err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to get template: " .. template_err
        })
        return
    end

    local metadata = {
        comment = data.description or "",
        template_id = data.template_id
    }

    local batch, batch_err = writer.for_user(user_id)
    if batch_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to create batch: " .. batch_err
        })
        return
    end

    batch, batch_err = batch:create_project(data.template_id, data.title, metadata)
    if batch_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to add create project command: " .. batch_err
        })
        return
    end

    if template.template and template.template.categories then
        for _, category in ipairs(template.template.categories) do
            batch, batch_err = batch:create_category(
                category.name,
                category.display_name or category.name,
                category.metadata or {}
            )
            if batch_err then
                res:set_status(http.STATUS.INTERNAL_ERROR)
                res:set_content_type(http.CONTENT.JSON)
                res:write_json({
                    success = false,
                    error = "Failed to add create category command: " .. batch_err
                })
                return
            end
        end
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

    res:set_status(http.STATUS.CREATED)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        project_id = batch.project_id,
        title = data.title,
        project_type = data.template_id,
        categories_created = template.template and template.template.categories and #template.template.categories or 0
    })
end

return {
    handler = handler
}