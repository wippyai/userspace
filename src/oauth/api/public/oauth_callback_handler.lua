local http = require("http")
local time = require("time")

-- Constants
local STATUS = http.STATUS
local CONTENT = http.CONTENT
local REGISTRY_PREFIX = "oauth:connection:"
local CALLBACK_TIMEOUT = "30s"
local CALLBACK_TOPIC = "oauth_callback"
local REPLY_TOPIC = "oauth_callback_response"

-- Error messages
local ERRORS = {
    MISSING_STATE = "Missing state parameter",
    OAUTH_PROVIDER_ERROR = "OAuth provider error",
    MISSING_CODE = "Missing authorization code",
    SESSION_NOT_FOUND = "OAuth session not found or expired",
    COMMUNICATION_FAILED = "Failed to communicate with OAuth session",
    SESSION_TIMEOUT = "OAuth session timeout",
    AUTH_FAILED = "OAuth authentication failed"
}

---@class CallbackParameters
---@field code string?
---@field state string?
---@field error string?
---@field error_description string?

---@param req any
---@return CallbackParameters
local function extract_callback_parameters(req)
    local callback_data = {
        code = req:query("code"),
        state = req:query("state"),
        error = req:query("error"),
        error_description = req:query("error_description")
    }

    -- Also check POST body if present
    if req:method() == "POST" and req:is_content_type(CONTENT.JSON) then
        local body, err = req:body_json()
        if not err and body then
            callback_data.code = callback_data.code or body.code
            callback_data.state = callback_data.state or body.state
            callback_data.error = callback_data.error or body.error
            callback_data.error_description = callback_data.error_description or body.error_description
        end
    end

    return callback_data
end

local function handler()
    local req = http.request()
    local res = http.response()

    res:set_content_type(CONTENT.JSON)

    -- Extract callback parameters
    local callback_data = extract_callback_parameters(req)

    -- Validate state
    if not callback_data.state or callback_data.state == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = ERRORS.MISSING_STATE
        })
        return
    end

    -- Handle OAuth errors
    if callback_data.error then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = ERRORS.OAUTH_PROVIDER_ERROR .. ": " .. callback_data.error,
            error_description = callback_data.error_description
        })
        return
    end

    -- Validate code
    if not callback_data.code or callback_data.code == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = ERRORS.MISSING_CODE
        })
        return
    end

    -- Find negotiator process
    local registry_name = REGISTRY_PREFIX .. callback_data.state
    local negotiator_pid = process.registry.lookup(registry_name)

    if not negotiator_pid then
        res:set_status(STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = ERRORS.SESSION_NOT_FOUND
        })
        return
    end

    -- Set up response channel
    local response_channel = process.listen(REPLY_TOPIC)

    -- Send callback to negotiator
    local send_success = process.send(negotiator_pid, CALLBACK_TOPIC, callback_data)
    if not send_success then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = ERRORS.COMMUNICATION_FAILED
        })
        return
    end

    -- Wait for response
    local timeout_channel = time.after(CALLBACK_TIMEOUT)
    local result = channel.select({
        response_channel:case_receive(),
        timeout_channel:case_receive()
    })

    if result.channel == timeout_channel then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = ERRORS.SESSION_TIMEOUT
        })
        return
    end

    -- Process response
    local response_data = result.value

    if not response_data.success then
        local status_code = response_data.oauth_error and STATUS.BAD_REQUEST or STATUS.INTERNAL_ERROR
        res:set_status(status_code)
        res:write_json({
            success = false,
            error = response_data.error or ERRORS.AUTH_FAILED
        })
        return
    end

    -- Return ONLY success confirmation - NO OAuth data
    res:set_status(STATUS.OK)
    res:write_json({
        success = true,
        message = "OAuth authentication successful"
    })
end

return {
    handler = handler
}