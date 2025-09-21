-- Function node with control command support
local ERROR_MISSING_FUNC_ID = "MISSING_FUNC_ID"
local ERROR_NO_INPUT_DATA = "NO_INPUT_DATA"
local ERROR_FUNCTION_CANCELED = "FUNCTION_CANCELED"
local ERROR_FUNCTION_EXECUTION_FAILED = "FUNCTION_EXECUTION_FAILED"

local func = {}

-- Exposed dependencies for testing
func._deps = {
    node = require("node"),
    funcs = require("funcs"),
    consts = require("consts")
}

-- Build execution context with dataflow information
local function build_execution_context_with_dataflow(base_context, dataflow_id, node_id, path)
    local execution_context = {}

    if base_context then
        for k, v in pairs(base_context) do
            execution_context[k] = v
        end
    end

    execution_context.dataflow_id = dataflow_id
    execution_context.node_id = node_id
    execution_context.path = path or {}
    execution_context.runtime_type = "dataflow_function"
    execution_context.execution_timestamp = os.time()

    return execution_context
end

local function run(args)
    local n, err = func._deps.node.new(args)
    if err then
        error(err)
    end

    -- Get function configuration from node config
    local config = n:config()
    local func_id = config.func_id
    if not func_id or func_id == "" then
        return n:fail({
            code = ERROR_MISSING_FUNC_ID,
            message = "Function ID not specified in node configuration"
        }, "Missing func_id in node config")
    end

    -- Get inputs and process them intelligently
    local inputs = n:inputs()
    local input_data = nil

    if next(inputs) == nil then
        input_data = nil
    elseif inputs.default then
        input_data = inputs.default.content
    elseif inputs[""] then
        input_data = inputs[""].content
    else
        local input_count = 0
        for _ in pairs(inputs) do
            input_count = input_count + 1
        end

        if input_count == 1 then
            for _, input in pairs(inputs) do
                input_data = input.content
                break
            end
        else
            input_data = {}
            for key, input in pairs(inputs) do
                input_data[key] = input.content
            end
        end
    end

    if input_data == nil then
        return n:fail({
            code = ERROR_NO_INPUT_DATA,
            message = "No input data provided for function node"
        }, "Function node requires input data")
    end

    -- Create function executor with context
    local executor = func._deps.funcs.new()
    local base_context = config.context
    local execution_context = build_execution_context_with_dataflow(
        base_context,
        n.dataflow_id,
        n.node_id,
        n.path
    )
    executor = executor:with_context(execution_context)

    -- Execute function asynchronously (for cancellation support)
    local command = executor:async(func_id, input_data)
    local response_channel = command:response()
    local events_channel = process.events()

    local result = channel.select({
        response_channel:case_receive(),
        events_channel:case_receive()
    })

    if result.channel == events_channel then
        local event = result.value
        if event.kind == process.event.CANCEL then
            command:cancel()
            return n:fail({
                code = ERROR_FUNCTION_CANCELED,
                message = "Function execution was canceled by system event"
            }, "Function execution was canceled")
        end
    end

    if command:is_canceled() then
        return n:fail({
            code = ERROR_FUNCTION_CANCELED,
            message = "Function execution was canceled"
        }, "Function execution was canceled")
    end

    local payload, result_err = command:result()
    if result_err then
        return n:fail({
            code = ERROR_FUNCTION_EXECUTION_FAILED,
            message = result_err
        }, "Function execution failed: " .. result_err)
    end

    local function_result = payload:data()

    -- Handle control commands if present
    if type(function_result) == "table" and function_result._control then
        local control = function_result._control
        local created_node_ids = {}

        -- Queue commands and track created nodes
        if control.commands and type(control.commands) == "table" then
            for _, cmd in ipairs(control.commands) do
                if cmd.type and cmd.payload then
                    n:command(cmd)
                    if cmd.type == func._deps.consts.COMMAND_TYPES.CREATE_NODE and cmd.payload.node_id then
                        table.insert(created_node_ids, cmd.payload.node_id)
                    end
                end
            end
        end

        -- If we created nodes, yield to run them and collect outputs
        if #created_node_ids > 0 then
            local yield_result, yield_err = n:yield({ run_nodes = created_node_ids })
            if yield_err then
                return n:fail({
                    code = ERROR_FUNCTION_EXECUTION_FAILED,
                    message = "Control command execution failed: " .. yield_err
                }, "Control command execution failed")
            end

            -- Collect outputs from created nodes
            local reader = n:query()
                :with_nodes(created_node_ids)
                :with_data_types(func._deps.consts.DATA_TYPE.NODE_OUTPUT)
                :fetch_options({ replace_references = true })

            local output_data = reader:all()

            if output_data and #output_data > 0 then
                -- Return collected outputs as function result
                local final_output
                if #output_data == 1 then
                    final_output = output_data[1].content
                else
                    local all_outputs = {}
                    for _, output in ipairs(output_data) do
                        table.insert(all_outputs, output.content)
                    end
                    final_output = all_outputs
                end

                return n:complete(final_output, "Function executed successfully")
            end
        end

        -- Remove _control and return cleaned result
        local cleaned_result = {}
        for k, v in pairs(function_result) do
            if k ~= "_control" then
                cleaned_result[k] = v
            end
        end

        return n:complete(cleaned_result, "Function executed successfully")
    end

    -- Normal function execution without control commands
    return n:complete(function_result, "Function executed successfully")
end

func.run = run
return func