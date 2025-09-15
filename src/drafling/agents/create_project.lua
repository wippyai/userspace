local json = require("json")
local security = require("security")
local writer = require("writer")
local template_registry = require("template_registry")

local function handler(params)
    local response = {
        success = false,
        project_id = nil,
        error = nil
    }

    if not params.template_id or params.template_id == "" then
        response.error = "Template ID is required"
        return response
    end

    if not params.title or params.title == "" then
        response.error = "Project title is required"
        return response
    end

    local actor = security.actor()
    if not actor then
        response.error = "Authentication required"
        return response
    end

    local user_id = actor:id()

    local template, template_err = template_registry.get_template(params.template_id)
    if template_err then
        response.error = "Failed to get template: " .. template_err
        return response
    end

    local metadata = {
        comment = params.description or "",
        template_id = params.template_id
    }

    local batch, batch_err = writer.for_user(user_id)
    if batch_err then
        response.error = "Failed to create batch: " .. batch_err
        return response
    end

    batch, batch_err = batch:create_project(params.template_id, params.title, metadata)
    if batch_err then
        response.error = "Failed to add create project command: " .. batch_err
        return response
    end

    if template.template and template.template.categories then
        for _, category in ipairs(template.template.categories) do
            batch, batch_err = batch:create_category(
                category.name,
                category.display_name or category.name,
                category.metadata or {}
            )
            if batch_err then
                response.error = "Failed to add create category command: " .. batch_err
                return response
            end
        end
    end

    local result, exec_err = batch:execute()
    if exec_err then
        response.error = "Failed to execute commands: " .. exec_err
        return response
    end

    response.success = true
    response.project_id = batch.project_id
    response.title = params.title
    response.template_id = params.template_id
    response.categories_created = template.template and template.template.categories and #template.template.categories or 0
    return response
end

return { handler = handler }