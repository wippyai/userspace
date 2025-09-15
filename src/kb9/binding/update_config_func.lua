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

    -- Build commands array based on what's being updated
    local commands = {}

    -- Add INIT_EMBED command if embed_contract is being updated
    if request_dto.embed_contract then
        if type(request_dto.embed_contract) ~= "table" or not request_dto.embed_contract.binding_id then
            return {
                success = false,
                error = { code = "INVALID_EMBED_CONTRACT", message = "Embed contract must have binding_id" }
            }
        end

        table.insert(commands, {
            type = consts.COMMAND_TYPES.INIT_EMBED,
            payload = {
                embed_contract = request_dto.embed_contract
            }
        })
    end

    -- Add INIT_QUERY command if query_contract is being updated
    if request_dto.query_contract then
        if type(request_dto.query_contract) ~= "table" or not request_dto.query_contract.binding_id then
            return {
                success = false,
                error = { code = "INVALID_QUERY_CONTRACT", message = "Query contract must have binding_id" }
            }
        end

        table.insert(commands, {
            type = consts.COMMAND_TYPES.INIT_QUERY,
            payload = {
                query_contract = request_dto.query_contract
            }
        })
    end

    if #commands == 0 then
        return {
            success = false,
            error = { code = "NO_UPDATES", message = "No valid configuration updates provided" }
        }
    end

    -- Send config update commands as array
    local current_pid = process.pid()
    local ack_responses = process.listen(consts.MESSAGE_TOPICS.KB_ASK)

    local update_cmd = {
        component_id = component_id,
        commands = commands,
        reply_to = current_pid
    }

    local ok, err = process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_COMMAND, update_cmd)
    if not ok then
        return {
            success = false,
            error = { code = "SEND_ERROR", message = "Failed to send config update commands: " .. (err or "unknown error") }
        }
    end

    print("Sent config update commands to KB9 root service for component:", component_id)

    -- Wait for acknowledgments from all sent commands
    local update_success = true
    local update_errors = {}
    local expected_acks = #commands
    local acks_received = 0
    local timeout = time.after(consts.ASK_TIMEOUT)

    while acks_received < expected_acks do
        local result = channel.select({
            ack_responses:case_receive(),
            timeout:case_receive()
        })

        if result.channel == timeout then
            table.insert(update_errors, "Timeout waiting for config update acknowledgments")
            update_success = false
            break
        end

        local ack = result.value
        acks_received = acks_received + 1

        if ack.startup_error then
            table.insert(update_errors, "KB startup failed: " .. (ack.error or "unknown error"))
            update_success = false
        elseif not ack.success then
            table.insert(update_errors, "Config update failed: " .. (ack.error or "unknown error"))
            update_success = false
        end
    end

    local response = {
        success = update_success,
        commands_sent = #commands,
        acks_received = acks_received
    }

    if #update_errors > 0 then
        response.errors = update_errors
        if not update_success then
            response.error = {
                code = "CONFIG_UPDATE_FAILED",
                message = "One or more config updates failed",
                details = update_errors
            }
        end
    end

    return response
end

return { handle = handle }