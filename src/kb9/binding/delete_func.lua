local ctx = require("ctx")
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

    -- Send DELETE_KB command to KB9 root service as array
    local current_pid = process.pid()
    local commands = {
        {
            type = consts.COMMAND_TYPES.DELETE_KB,
            payload = {}
        }
    }

    local delete_cmd = {
        component_id = component_id,
        commands = commands,
        reply_to = current_pid
    }

    -- Send command to root service
    local ok, err = process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_COMMAND, delete_cmd)
    if not ok then
        return {
            success = false,
            error = { code = "SEND_ERROR", message = "Failed to send command to root service: " .. (err or "unknown error") }
        }
    end

    print("Sent DELETE_KB command to KB9 root service for component:", component_id)

    -- Wait for acknowledgment response with timeout
    local ack_responses = process.listen(consts.MESSAGE_TOPICS.KB_ASK)
    local timeout = time.after(consts.DELETE_TIMEOUT)

    local result = channel.select({
        ack_responses:case_receive(),
        timeout:case_receive()
    })

    if result.channel == timeout then
        return {
            success = false,
            error = { code = "ACK_TIMEOUT", message = "Timeout waiting for KB process acknowledgment" }
        }
    end

    local ack = result.value

    -- Handle startup errors
    if ack.startup_error then
        return {
            success = false,
            error = { code = "KB_STARTUP_ERROR", message = "KB process failed to start: " .. (ack.error or "unknown error") }
        }
    end

    -- Handle command acknowledgment
    if not ack.success then
        return {
            success = false,
            error = { code = "KB_PROCESS_ERROR", message = ack.error or "KB process returned error" }
        }
    end

    return {
        success = true,
        ops_executed = ack.ops_executed or 0,
        message = ack.message or "KB deleted successfully"
    }
end

return { handle = handle }