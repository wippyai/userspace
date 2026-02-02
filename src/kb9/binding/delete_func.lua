local ctx = require("ctx")
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

    local current_pid = process.pid()

    -- Send command to root service
    local ok, err = process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_COMMAND, {
        component_id = component_id,
        commands = {
            {
                type = consts.COMMAND_TYPES.DELETE_KB,
                payload = {}
            }
        },
        reply_to = current_pid
    })
    if not ok then
        return {
            success = false,
            error = { code = "SEND_ERROR", message = "Failed to send command to root service: " .. (err or "unknown error") }
        }
    end

    return {
        success = true,
        message = "KB deletion process successfully started"
    }
end

return { handle = handle }
