local json = require("json")
local security = require("security")
local doc_repo = require("doc_repo")
local template_registry = require("template_registry")

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

    local project, proj_err = doc_repo.get(params.project_id, user_id)
    if proj_err then
        response.error = "Project not found or access denied"
        return response
    end

    local target_agent_id = params.agent_id

    if not target_agent_id then
        if project.project_type then
            local template, template_err = template_registry.get_template(project.project_type)
            if not template_err and template and template.template.agent_id then
                target_agent_id = template.template.agent_id
            end
        end

        if not target_agent_id then
            target_agent_id = "userspace.drafling.agents:drafling_agent"
        end
    end

    local control = {
        context = {
            session = {
                set = {
                    project_id = params.project_id,
                    project_title = project.title,
                    project_type = project.project_type
                },
            },
            public_meta = {
                set = {
                    {
                        id = "project_name",
                        title = project.title or params.project_id,
                        display_name = "Project: " .. (project.title or params.project_id),
                        type = "project",
                        icon = "tabler:pencil"
                    }
                }
            }
        },
        config = {
            agent = target_agent_id
        }
    }

    response.success = true
    response.message = string.format("Switching to project agent for: %s", project.title or params.project_id)
    response.project = {
        id = params.project_id,
        title = project.title,
        type = project.project_type
    }
    response.agent = {
        id = target_agent_id
    }
    response._control = control

    return response
end

return { handler = handler }
