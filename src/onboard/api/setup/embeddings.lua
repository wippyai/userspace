local http = require("http")
local json = require("json")
local security = require("security")
local env = require("env")
local http_client = require("http_client")

local function validate_openai_key(api_key)
    if not api_key or api_key == "" then
        return false, "No API key provided"
    end

    local pattern = "^sk%-[A-Za-z0-9_%-]+$"
    local min_length = 20

    if #api_key < min_length then
        return false, "OpenAI key must be at least 20 characters"
    end

    if not string.match(api_key, pattern) then
        return false, "OpenAI key must start with 'sk-'"
    end

    if string.find(string.lower(api_key), "test") or
       string.find(string.lower(api_key), "example") or
       string.find(string.lower(api_key), "your") then
        return false, "Invalid API key format"
    end

    return true, "Format valid"
end

local function test_openai_connection(api_key)
    local format_valid, format_error = validate_openai_key(api_key)
    if not format_valid then
        return false, format_error
    end

    local response, err = http_client.get("https://api.openai.com/v1/models", {
        headers = {
            ["Authorization"] = "Bearer " .. api_key
        },
        timeout = 10
    })

    if err then
        return false, "Connection failed: " .. err
    end

    if response.status_code == 200 then
        return true, "Connected successfully"
    elseif response.status_code == 401 or response.status_code == 403 then
        return false, "Invalid API key"
    else
        return false, "API error: " .. response.status_code
    end
end

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    if req:method() ~= http.METHOD.POST then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Only POST method allowed"
        })
        return
    end

    if not req:is_content_type(http.CONTENT.JSON) then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Content-Type must be application/json"
        })
        return
    end

    local body, err = req:body_json()
    if err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Invalid JSON: " .. err
        })
        return
    end

    if not body.openai_key or body.openai_key == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "OpenAI API key is required"
        })
        return
    end

    local success, message = test_openai_connection(body.openai_key)

    if success then
        env.set("OPENAI_API_KEY", body.openai_key)
    end

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