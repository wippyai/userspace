local ctx = require("ctx")
local json = require("json")
local time = require("time")
local consts = require("consts")

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            success = false
        }
    end

    -- Validate request
    if not request_dto or type(request_dto) ~= "table" then
        return {
            success = false
        }
    end

    if not request_dto.content or type(request_dto.content) ~= "string" or request_dto.content == "" then
        return {
            success = false
        }
    end

    if not request_dto.content_type or type(request_dto.content_type) ~= "string" or request_dto.content_type == "" then
        return {
            success = false
        }
    end

    -- Send EMBED_CONTENT command to KB9 root service
    local current_pid = process.pid()
    local commands = {
        {
            type = consts.COMMAND_TYPES.EMBED_CONTENT,
            payload = {
                content = request_dto.content,
                content_type = request_dto.content_type,
                metadata = request_dto.metadata or {}
            }
        }
    }

    local embed_cmd = {
        component_id = component_id,
        commands = commands,
        reply_to = current_pid
    }

    -- Send command to root service
    local ok, send_err = process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_COMMAND, embed_cmd)
    if not ok then
        return {
            success = false
        }
    end

    -- Wait for acknowledgment response with timeout
    local ack_responses = process.listen(consts.MESSAGE_TOPICS.KB_ASK)
    local timeout = time.after(consts.EMBED_TIMEOUT)

    local result = channel.select({
        ack_responses:case_receive(),
        timeout:case_receive()
    })

    if result.channel == timeout then
        return {
            success = false
        }
    end

    local ack = result.value

    -- Handle startup errors
    if ack.startup_error then
        return {
            success = false
        }
    end

    -- Handle command acknowledgment
    if not ack.success then
        return {
            success = false
        }
    end

    -- Return universal embeddable format
    return {
        success = true
    }
end

return { handle = handle }