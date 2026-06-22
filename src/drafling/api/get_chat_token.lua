local http = require("http")
local security = require("security")
local json = require("json")
local start_tokens = require("start_tokens")
local doc_repo = require("doc_repo")
local template_registry = require("template_registry")
local agent_registry = require("agent_registry")
local api_error = require("api_error")

local DEFAULT_AGENT_ID = "userspace.drafling.agents:drafling_agent"

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

    local project, proj_err = doc_repo.get(project_id, user_id)
    if proj_err then
        res:set_status(http.STATUS.NOT_FOUND)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Project not found"
        })
        return
    end

    local agent_id = DEFAULT_AGENT_ID

    if project.project_type then
        local template, template_err = template_registry.get_template(project.project_type)
        if not template_err and template and template.template.agent_id then
            agent_id = template.template.agent_id
        end
    end

    local agent_spec, agent_err = agent_registry.get_by_id(agent_id)
    if agent_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to load agent", agent_err)
        return
    end

    if not agent_spec.model then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Agent has no model specified"
        })
        return
    end

    local session_params = {
        agent = agent_id,
        model = agent_spec.model,
        kind = "project_assistant",
        context = {
            project_id = project_id
        },
    }

    local start_token, token_err = start_tokens.pack(session_params)
    if token_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to create start token", token_err)
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        start_token = start_token,
        agent_id = agent_id,
        agent_name = agent_spec.title or agent_spec.name,
        project_id = project_id
    })
end

return {
    handler = handler
}