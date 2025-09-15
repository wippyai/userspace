local ctx = require("ctx")
local json = require("json")
local time = require("time")
local consts = require("consts")

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return nil, "No component context: " .. err
    end

    -- Validate request
    if not request_dto or type(request_dto) ~= "table" then
        return nil, "Request must be a table"
    end

    if not request_dto.reference or type(request_dto.reference) ~= "table" then
        return nil, "Reference must be a table"
    end

    -- Convert universal reference format to KB9 reference format
    local reference = request_dto.reference
    local kb9_reference

    if reference.component_id then
        -- Universal format: convert to KB9 format
        kb9_reference = {
            binding_id = reference.component_id,
            context = reference.context or {}
        }
    elseif reference.binding_id then
        -- Already in KB9 format
        kb9_reference = reference
    else
        return nil, "Reference must have either component_id or binding_id"
    end

    -- Send EMBED_REFERENCE command to KB9 root service
    local current_pid = process.pid()
    local commands = {
        {
            type = consts.COMMAND_TYPES.EMBED_REFERENCE,
            payload = {
                reference = kb9_reference,
                metadata = request_dto.metadata or {}
            }
        }
    }

    local embed_ref_cmd = {
        component_id = component_id,
        commands = commands,
        reply_to = current_pid
    }

    -- Send command to root service
    local ok, send_err = process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_COMMAND, embed_ref_cmd)
    if not ok then
        return nil, "Failed to send command to root service: " .. (send_err or "unknown error")
    end

    -- Wait for acknowledgment response with timeout
    local ack_responses = process.listen(consts.MESSAGE_TOPICS.KB_ASK)
    local timeout = time.after(consts.EMBED_TIMEOUT)

    local result = channel.select({
        ack_responses:case_receive(),
        timeout:case_receive()
    })

    if result.channel == timeout then
        return nil, "Timeout waiting for KB process acknowledgment"
    end

    local ack = result.value

    -- Handle startup errors
    if ack.startup_error then
        return nil, "KB process failed to start: " .. (ack.error or "unknown error")
    end

    -- Handle command acknowledgment
    if not ack.success then
        return nil, ack.error or "KB process returned error"
    end

    -- Return universal embeddable format
    return {
        success = true,
    }, nil
end

return { handle = handle }
