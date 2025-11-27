local http = require("http")
local json = require("json")
local security = require("security")
local env = require("env")
local http_client = require("http_client")
local logger = require("logger")
local log = logger:named("userspace.onboard.api.setup.embeddings")

-- Constants
local OPENAI_API_KEY_PATTERN = "^sk%-[A-Za-z0-9_%-]+$"
local MIN_API_KEY_LENGTH = 20
local OPENAI_API_BASE_URL = "https://api.openai.com"
local OPENAI_API_TIMEOUT = 10
local INVALID_KEY_PATTERNS = { "test", "example", "your" }

-- Validates OpenAI API key format
local function validate_openai_key(api_key)
    if not api_key or api_key == "" then
        return false, "No API key provided"
    end

    if #api_key < MIN_API_KEY_LENGTH then
        return false, "OpenAI key must be at least 20 characters"
    end

    if not string.match(api_key, OPENAI_API_KEY_PATTERN) then
        return false, "OpenAI key must start with 'sk-'"
    end

    local lower_key = string.lower(api_key)
    for _, pattern in ipairs(INVALID_KEY_PATTERNS) do
        if string.find(lower_key, pattern) then
            return false, "Invalid API key format"
        end
    end

    return true, "Format valid"
end

-- Tests OpenAI API connection with the provided API key
local function test_openai_connection(api_key)
    local format_valid, format_error = validate_openai_key(api_key)
    if not format_valid then
        return false, format_error
    end

    local response, err = http_client.get(OPENAI_API_BASE_URL .. "/v1/models", {
        headers = {
            ["Authorization"] = "Bearer " .. api_key
        },
        timeout = OPENAI_API_TIMEOUT
    })

    if err then
        log:error("HTTP request error", { error = err })
        return false, "Connection failed: " .. err
    end

    if not response then
        log:error("No response received from OpenAI API", {})
        return false, "No response received from OpenAI API"
    end

    local status = response.status_code
    if status == 200 then
        return true, "Connected successfully"
    elseif status == 401 or status == 403 then
        log:warn("Invalid API key", { status_code = status })
        return false, "Invalid API key"
    else
        log:warn("API error", { status_code = status })
        return false, "API error: " .. status
    end
end

-- HTTP handler for OpenAI embeddings setup endpoint
local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        log:error("Failed to get HTTP context", {})
        return nil, "Failed to get HTTP context"
    end

    -- Verify authentication
    local actor = security.actor()
    if not actor then
        log:warn("Authentication required - no actor found", {})
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    -- Validate HTTP method
    if req:method() ~= http.METHOD.POST then
        log:warn("Invalid method", { method = req:method() })
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Only POST method allowed"
        })
        return
    end

    -- Validate content type
    if not req:is_content_type(http.CONTENT.JSON) then
        log:warn("Invalid content type", {})
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Content-Type must be application/json"
        })
        return
    end

    -- Parse request body
    local body, err = req:body_json()
    if err then
        log:error("JSON parse error", { error = err })
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Invalid JSON: " .. err
        })
        return
    end

    -- Validate API key presence
    if not body.openai_key or body.openai_key == "" then
        log:warn("OpenAI API key is missing", {})
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "OpenAI API key is required"
        })
        return
    end

    -- Test OpenAI connection
    local success, message = test_openai_connection(body.openai_key)

    if success then
        -- Set environment variable
        env.set("OPENAI_API_KEY", body.openai_key)

        -- Verify the key was set correctly
        local verify_key, verify_err = env.get("OPENAI_API_KEY")

        if verify_err then
            log:error("Failed to get environment variable for verification", { error = verify_err })
            res:set_status(500)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Failed to verify environment variable was set"
            })
            return
        elseif not verify_key or verify_key ~= body.openai_key then
            log:error("Environment variable verification failed", {
                expected_length = #body.openai_key,
                got_length = verify_key and #verify_key or 0
            })
            res:set_status(500)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Environment variable was not set correctly"
            })
            return
        end
    end

    -- Send response
    local status_code = success and http.STATUS.OK or http.STATUS.BAD_REQUEST
    res:set_status(status_code)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = success,
        message = success and "OpenAI embeddings enabled successfully!" or message,
        summary = {
            string.format("OpenAI Embeddings: %s", success and "✓ Enabled" or "✗ " .. message)
        }
    })
end

return {
    handler = handler
}
