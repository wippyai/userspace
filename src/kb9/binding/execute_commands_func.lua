local ctx = require("ctx")
local json = require("json")
local time = require("time")
local consts = require("consts")

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            success = false,
            error = { code = "NO_CONTEXT", message = "No component context: " .. err }
        }
    end

    -- Validate request
    if not request_dto or type(request_dto) ~= "table" then
        return {
            success = false,
            error = { code = "INVALID_REQUEST", message = "Request must be a table" }
        }
    end

    if not request_dto.commands or type(request_dto.commands) ~= "table" or #request_dto.commands == 0 then
        return {
            success = false,
            error = { code = "INVALID_COMMANDS", message = "Commands array is required and must not be empty" }
        }
    end

    -- Validate each command
    for i, command in ipairs(request_dto.commands) do
        if type(command) ~= "table" then
            return {
                success = false,
                error = { code = "INVALID_COMMAND", message = "Command " .. i .. " must be a table" }
            }
        end

        if not command.type or type(command.type) ~= "string" then
            return {
                success = false,
                error = { code = "INVALID_COMMAND_TYPE", message = "Command " .. i .. " must have a string type" }
            }
        end

        if not command.payload or type(command.payload) ~= "table" then
            return {
                success = false,
                error = { code = "INVALID_COMMAND_PAYLOAD", message = "Command " .. i .. " must have a table payload" }
            }
        end

        -- Validate command type is known
        local valid_types = {
            [consts.COMMAND_TYPES.CREATE_NODE] = true,
            [consts.COMMAND_TYPES.UPDATE_NODE] = true,
            [consts.COMMAND_TYPES.DELETE_NODE] = true,
            [consts.COMMAND_TYPES.DELETE_NODES] = true,
            [consts.COMMAND_TYPES.MOVE_NODE] = true,
            [consts.COMMAND_TYPES.CREATE_EDGE] = true,
            [consts.COMMAND_TYPES.UPDATE_EDGE] = true,
            [consts.COMMAND_TYPES.DELETE_EDGE] = true,
            [consts.COMMAND_TYPES.DELETE_EDGES] = true,
            [consts.COMMAND_TYPES.UPSERT_EMBEDDING] = true,
            [consts.COMMAND_TYPES.DELETE_EMBEDDING] = true
        }

        if not valid_types[command.type] then
            return {
                success = false,
                error = { code = "UNKNOWN_COMMAND_TYPE", message = "Unknown command type: " .. command.type }
            }
        end
    end

    -- Setup for acknowledgments
    local current_pid = process.pid()
    local ack_responses = process.listen(consts.MESSAGE_TOPICS.KB_ASK)
    local total_ops_executed = 0

    -- Send all commands as a single array (simplified approach)
    local cmd_message = {
        component_id = component_id,
        commands = request_dto.commands,
        reply_to = current_pid
    }

    local ok, err = process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_COMMAND, cmd_message)
    if not ok then
        return {
            success = false,
            error = { code = "SEND_ERROR", message = "Failed to send commands: " .. (err or "unknown error") }
        }
    end

    print("Sent command array with " .. #request_dto.commands .. " commands")

    -- Wait for acknowledgments from all sent commands
    local execution_success = true
    local execution_errors = {}
    local expected_acks = #request_dto.commands
    local acks_received = 0
    local timeout = time.after(consts.ASK_TIMEOUT)

    while acks_received < expected_acks do
        local result = channel.select({
            ack_responses:case_receive(),
            timeout:case_receive()
        })

        if result.channel == timeout then
            table.insert(execution_errors, "Timeout waiting for command acknowledgments")
            execution_success = false
            break
        end

        local ack = result.value
        acks_received = acks_received + 1

        if ack.startup_error then
            table.insert(execution_errors, "KB startup failed: " .. (ack.error or "unknown error"))
            execution_success = false
        elseif not ack.success then
            table.insert(execution_errors, "Command execution failed: " .. (ack.error or "unknown error"))
            execution_success = false
        else
            -- Accumulate ops executed
            total_ops_executed = total_ops_executed + (ack.ops_executed or 0)
        end
    end

    if execution_success then
        return {
            success = true,
            ops_executed = total_ops_executed
        }
    else
        return {
            success = false,
            error = {
                code = "EXECUTION_FAILED",
                message = "Command execution failed: " .. table.concat(execution_errors, "; ")
            }
        }
    end
end

return { handle = handle }