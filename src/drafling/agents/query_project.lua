local json = require("json")
local security = require("security")
local doc_repo = require("doc_repo")
local template_registry = require("template_registry")
local uuid = require("uuid")
local client = require("client")
local consts = require("consts")
local agent_registry = require("agent_registry")
local ctx = require("ctx")

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

    if not params.query or params.query == "" then
        response.error = "Query is required"
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

    local target_agent_id = "userspace.drafling.agents:drafling_agent"

    if project.project_type then
        local template, template_err = template_registry.get_template(project.project_type)
        if not template_err and template and template.template and template.template.agent_id then
            target_agent_id = template.template.agent_id
        end
    end

    local agent_spec, lookup_err = agent_registry.get_by_id(target_agent_id)
    if not agent_spec then
        response.error = "Project agent not found: " .. target_agent_id
        return response
    end

    local agent_title = "Project Agent"
    if agent_spec and agent_spec.title then
        agent_title = agent_spec.title
    elseif agent_spec and agent_spec.name then
        agent_title = agent_spec.name
    end

    -- Get all session context first (like delegate_to_agent does)
    local session_context, ctx_err = ctx.all()
    if ctx_err then
        session_context = {}
    end

    -- Build project delegation context
    local delegation_context = {
        project_id = params.project_id,
        project_title = project.title,
        project_type = project.project_type,
        user_id = user_id,
        delegation_type = "project_query",
        from_agent_id = "userspace.drafling.agents:project_manager"
    }

    -- Merge project context into session context
    for k, v in pairs(delegation_context) do
        session_context[k] = v
    end

    -- Add delegation metadata like delegate_to_agent does
    session_context.to_agent_id = target_agent_id

    -- Merge any additional provided context
    if params.context and type(params.context) == "table" then
        for k, v in pairs(params.context) do
            session_context[k] = v
        end
    end

    local c, client_err = client.new()
    if client_err then
        response.error = "Failed to create dataflow client: " .. client_err
        return response
    end

    local node_id = uuid.v7()
    local input_data_id = uuid.v7()
    local node_input_id = uuid.v7()

    local workflow_commands = {
        {
            type = consts.COMMAND_TYPES.CREATE_NODE,
            payload = {
                node_id = node_id,
                node_type = "userspace.dataflow.node.agent:node",
                status = consts.STATUS.PENDING,
                config = {
                    agent = target_agent_id,
                    arena = {
                        prompt = params.query,
                        max_iterations = session_context.max_iterations or 16,
                        min_iterations = 1,
                        tool_calling = "auto",
                        context = session_context
                    },
                    data_targets = {
                        { data_type = consts.DATA_TYPE.WORKFLOW_OUTPUT, content_type = consts.CONTENT_TYPE.JSON }
                    }
                },
                metadata = {
                    title = "Project Query: " .. (project.title or params.project_id),
                    project_id = params.project_id,
                    agent_title = agent_title,
                    delegation_from = session_context.from_agent_id or "userspace.drafling.agents:project_manager",
                    delegation_type = "project_query"
                }
            }
        },
        {
            type = consts.COMMAND_TYPES.CREATE_DATA,
            payload = {
                data_id = input_data_id,
                data_type = consts.DATA_TYPE.WORKFLOW_INPUT,
                content = params.query,
                content_type = consts.CONTENT_TYPE.TEXT
            }
        },
        {
            type = consts.COMMAND_TYPES.CREATE_DATA,
            payload = {
                data_id = node_input_id,
                data_type = consts.DATA_TYPE.NODE_INPUT,
                key = input_data_id,
                node_id = node_id,
                content_type = consts.CONTENT_TYPE.REFERENCE,
                content = ""
            }
        }
    }

    local dataflow_id, create_err = c:create_workflow(workflow_commands, {
        metadata = {
            title = "Query: " .. (project.title or params.project_id),
            delegation_type = "project_query",
            target_agent = target_agent_id,
            source_agent = "userspace.drafling.agents:project_manager",
            project_id = params.project_id,
            query = params.query,
            created_by = "userspace.drafling.agents:query_project"
        }
    })

    if create_err then
        response.error = "Failed to create project query workflow: " .. create_err
        return response
    end

    local result, exec_err = c:execute(dataflow_id, {
        init_func_id = "userspace.dataflow.session:artifact"
    })

    if exec_err then
        response.error = "Failed to execute project query: " .. exec_err
        return response
    end

    response.success = true
    response.project = {
        id = params.project_id,
        title = project.title,
        agent_id = target_agent_id,
        agent_title = agent_title
    }
    response.query = params.query
    response.result = result
    response.workflow_id = dataflow_id

    return response
end

return { handler = handler }