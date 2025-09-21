local json = require("json")
local uuid = require("uuid")
local ctx = require("ctx")
local compiler = require("compiler")
local client = require("client")
local consts = require("consts")
local registry = require("registry")

-- Configuration constants
local DEFAULTS = {
    AGENT_MAX_ITERATIONS = 32,
    AGENT_MIN_ITERATIONS = 1,
    AGENT_TOOL_CALLING = "auto",
    MAP_REDUCE_BATCH_SIZE = 1,
    MAP_REDUCE_FAILURE_STRATEGY = "fail_fast",
    MAP_REDUCE_ITERATION_INPUT_KEY = "default"
}

local flow = {}

-- Helper function to get title from registry
local function get_registry_title(id)
    if not id or id == "" then
        return nil
    end

    local entry, err = registry.get(id)
    if entry and entry.meta and (entry.meta.title or entry.meta.name) then
        return entry.meta.title or entry.meta.name
    end

    return nil
end

-- FlowBuilder class
local FlowBuilder = {}
local flow_builder_mt = { __index = FlowBuilder }

function FlowBuilder.new()
    return setmetatable({
        operations = {},
        is_template = false
    }, flow_builder_mt)
end

function FlowBuilder:_mark_as_template()
    self.is_template = true
    return self
end

function FlowBuilder:_add_operation(op_type, config)
    table.insert(self.operations, {
        type = op_type,
        config = config or {}
    })
    return self, nil
end

-- Input methods
function FlowBuilder:with_input(data)
    return self:_add_operation(compiler.OP_TYPES.WITH_INPUT, { data = data })
end

-- Transform methods
function FlowBuilder:transform(expression)
    if not expression or expression == "" then
        return nil, "Transform expression is required"
    end
    return self:_add_operation(compiler.OP_TYPES.TRANSFORM, { expression = expression })
end

-- Node creation methods
function FlowBuilder:func(func_id, config)
    if not func_id or func_id == "" then
        return nil, "Function ID is required"
    end

    local func_config = {
        func_id = func_id,
        context = config and config.context,
        metadata = config and config.metadata
    }

    -- Auto-populate title from registry if not provided
    if not (func_config.metadata and func_config.metadata.title) then
        local registry_title = get_registry_title(func_id)
        if registry_title then
            if not func_config.metadata then
                func_config.metadata = {}
            end
            func_config.metadata.title = registry_title
        end
    end

    return self:_add_operation(compiler.OP_TYPES.FUNC, func_config)
end

function FlowBuilder:agent(agent_id, config)
    if not agent_id or agent_id == "" then
        return nil, "Agent ID is required"
    end

    config = config or {}
    local arena_config = config.arena or {}

    if not arena_config.prompt then
        return nil, "Arena prompt is required for agent nodes"
    end

    local agent_config = {
        agent_id = agent_id,
        arena = {
            prompt = arena_config.prompt,
            max_iterations = arena_config.max_iterations or DEFAULTS.AGENT_MAX_ITERATIONS,
            min_iterations = arena_config.min_iterations or DEFAULTS.AGENT_MIN_ITERATIONS,
            tool_calling = arena_config.tool_calling or DEFAULTS.AGENT_TOOL_CALLING,
            exit_schema = arena_config.exit_schema,
            tools = arena_config.tools,
            context = arena_config.context
        },
        inputs = config.inputs,
        show_tool_calls = config.show_tool_calls,
        metadata = config.metadata
    }

    -- Auto-populate title from registry if not provided
    if not (agent_config.metadata and agent_config.metadata.title) then
        local registry_title = get_registry_title(agent_id)
        if registry_title then
            if not agent_config.metadata then
                agent_config.metadata = {}
            end
            agent_config.metadata.title = registry_title
        end
    end

    return self:_add_operation(compiler.OP_TYPES.AGENT, agent_config)
end

function FlowBuilder:cycle(config)
    if not config then
        return nil, "Cycle configuration is required"
    end

    if not config.func_id and not config.template then
        return nil, "Cycle requires either func_id or template"
    end

    if config.func_id and config.template then
        return nil, "Cycle cannot have both func_id and template"
    end

    local cycle_config = {
        func_id = config.func_id,
        template = config.template,
        continue_condition = config.continue_condition,
        max_iterations = config.max_iterations,
        initial_state = config.initial_state,
        context = config.context,
        metadata = config.metadata
    }

    -- Auto-populate title if not provided
    if not (cycle_config.metadata and cycle_config.metadata.title) then
        if config.func_id then
            local registry_title = get_registry_title(config.func_id)
            if registry_title then
                if not cycle_config.metadata then
                    cycle_config.metadata = {}
                end
                cycle_config.metadata.title = registry_title .. " (Cycle)"
            end
        else
            if not cycle_config.metadata then
                cycle_config.metadata = {}
            end
            cycle_config.metadata.title = "Iterate"
        end
    end

    return self:_add_operation(compiler.OP_TYPES.CYCLE, cycle_config)
end

function FlowBuilder:parallel(branches)
    if not branches or type(branches) ~= "table" or next(branches) == nil then
        return nil, "Parallel branches configuration is required"
    end

    local parallel_config = {
        branches = branches
    }

    return self:_add_operation(compiler.OP_TYPES.PARALLEL, parallel_config)
end

function FlowBuilder:map_reduce(config)
    if not config then
        return nil, "Map-reduce configuration is required"
    end

    if not config.source_array_key then
        return nil, "Map-reduce requires source_array_key"
    end

    local mr_config = {
        source_array_key = config.source_array_key,
        iteration_input_key = config.iteration_input_key or DEFAULTS.MAP_REDUCE_ITERATION_INPUT_KEY,
        batch_size = config.batch_size or DEFAULTS.MAP_REDUCE_BATCH_SIZE,
        failure_strategy = config.failure_strategy or DEFAULTS.MAP_REDUCE_FAILURE_STRATEGY,
        template = config.template, -- Template passed as parameter
        item_steps = config.item_steps,
        reduction_extract = config.reduction_extract,
        reduction_steps = config.reduction_steps,
        metadata = config.metadata
    }

    -- Auto-populate title if not provided
    if not (mr_config.metadata and mr_config.metadata.title) then
        if not mr_config.metadata then
            mr_config.metadata = {}
        end
        mr_config.metadata.title = "Process Items"
    end

    return self:_add_operation(compiler.OP_TYPES.MAP_REDUCE, mr_config)
end

function FlowBuilder:use(template)
    if not template then
        return nil, "Template is required for use operation"
    end

    -- If template is a FlowBuilder, get its operations
    if type(template) == "table" and template.operations then
        return self:_add_operation(compiler.OP_TYPES.USE, { operations = template.operations })
    else
        return self:_add_operation(compiler.OP_TYPES.USE, { template = template })
    end
end

-- Naming and routing methods
function FlowBuilder:as(name)
    if not name or name == "" then
        return nil, "Node name is required"
    end
    return self:_add_operation(compiler.OP_TYPES.AS, { name = name })
end

function FlowBuilder:to(target)
    if not target or target == "" then
        return nil, "Route target is required"
    end
    return self:_add_operation(compiler.OP_TYPES.TO, { target = target })
end

function FlowBuilder:error_to(target)
    if not target or target == "" then
        return nil, "Error route target is required"
    end
    return self:_add_operation(compiler.OP_TYPES.ERROR_TO, { target = target })
end

function FlowBuilder:when(condition)
    if not condition or condition == "" then
        return nil, "Route condition is required"
    end
    return self:_add_operation(compiler.OP_TYPES.WHEN, { condition = condition })
end

-- Execution methods
function FlowBuilder:run()
    if #self.operations == 0 then
        return nil, "No operations to execute"
    end

    -- Detect execution context
    local session_context, ctx_err = ctx.all()
    if ctx_err then
        session_context = {}
    end

    -- Compile operations to commands
    local compilation_result, compile_err = compiler.compile(self.operations, session_context)
    if compile_err then
        return nil, "Compilation failed: " .. compile_err
    end

    local commands = compilation_result.commands

    -- DEBUG: Print compiled commands as JSON
    print("=== FLOW COMMANDS JSON ===")
    for i, cmd in ipairs(commands) do
        print("Command " .. i .. ":", json.encode(cmd))
    end
    print("=== END COMMANDS ===")

    if session_context.dataflow_id then
        -- Inside dataflow session: return control commands
        return {
            _control = {
                commands = commands
            }
        }, nil
    else
        -- Standalone context: execute workflow with artifact
        local c, client_err = client.new()
        if client_err then
            return nil, "Failed to create dataflow client: " .. client_err
        end

        local dataflow_id, create_err = c:create_workflow(commands, {
            metadata = {
                title = "Flow Builder Workflow",
                created_by = "flow_builder"
            }
        })

        if create_err then
            return nil, "Failed to create workflow: " .. create_err
        end

        local result, exec_err = c:execute(dataflow_id, {
            init_func_id = "userspace.dataflow.session:artifact"
        })

        if exec_err then
            return nil, "Failed to execute workflow: " .. exec_err
        end

        return result, nil
    end
end

-- Public API
function flow.create()
    return FlowBuilder.new(), nil
end

function flow.template()
    return FlowBuilder.new():_mark_as_template(), nil
end

return flow