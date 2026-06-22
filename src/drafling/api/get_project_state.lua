local http = require("http")
local json = require("json")
local security = require("security")
local doc_reader = require("doc_reader")
local template_registry = require("template_registry")
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

    -- Use doc_reader to get complete project state with categories and entries
    local reader, reader_err = doc_reader.with_user(user_id)
    if reader_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to create reader", reader_err)
        return
    end

    local project, project_err = reader
        :with_projects(project_id)
        :include_categories()
        :include_entries()
        :one()

    if project_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get project data", project_err)
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

    -- Get template information
    local template = nil
    local template_id = project.project_type
    if project.metadata and project.metadata.template_id then
        template_id = project.metadata.template_id
    end

    if template_id and template_id ~= "" then
        local template_data, template_err = template_registry.get_template(template_id)
        if template_err then
            -- Don't fail the request if template is missing, just log it
            template = nil
        else
            template = template_data
        end
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        project = project,
        template = template
    })
end

return {
    handler = handler
}