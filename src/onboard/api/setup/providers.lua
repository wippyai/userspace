local http = require("http")
local json = require("json")
local security = require("security")
local env = require("env")
local http_client = require("http_client")

local function validate_api_key_format(provider_name, api_key)
    if not api_key or api_key == "" then
        return false, "No API key provided"
    end

    local format_rules = {
        openrouter = {
            pattern = "^sk%-or%-v1%-[A-Za-z0-9_%-]+$",
            min_length = 20,
            error = "OpenRouter key must start with 'sk-or-v1-' and be at least 20 characters"
        },
        openai = {
            pattern = "^sk%-[A-Za-z0-9_%-]+$",
            min_length = 20,
            error = "OpenAI key must start with 'sk-' and be at least 20 characters"
        }
    }

    local rule = format_rules[provider_name]
    if not rule then
        return false, "Unknown provider"
    end

    if #api_key < rule.min_length then
        return false, rule.error
    end

    if not string.match(api_key, rule.pattern) then
        return false, rule.error
    end

    -- Additional sanity checks
    if string.find(string.lower(api_key), "test") or
       string.find(string.lower(api_key), "example") or
       string.find(string.lower(api_key), "your") then
        return false, "Invalid API key format"
    end

    return true, "Format valid"
end

local function test_provider_status(provider_name, api_key)
    local format_valid, format_error = validate_api_key_format(provider_name, api_key)
    if not format_valid then
        return false, format_error
    end

    local test_configs = {
        openrouter = {
            url = "https://openrouter.ai/api/v1/models",
            headers = {
                ["Authorization"] = "Bearer " .. api_key,
                ["HTTP-Referer"] = "https://wippy.ai",
                ["X-Title"] = "Wippy"
            }
        },
        openai = {
            url = "https://api.openai.com/v1/models",
            headers = {
                ["Authorization"] = "Bearer " .. api_key
            }
        }
    }

    local config = test_configs[provider_name]
    if not config then
        return false, "Unknown provider"
    end

    local response, err = http_client.get(config.url, {
        headers = config.headers,
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

    -- Validate required OpenRouter key
    if not body.openrouter or body.openrouter == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "OpenRouter API key is required"
        })
        return
    end

    -- Test providers BEFORE setting any environment variables
    local openrouter_healthy, openrouter_message = test_provider_status("openrouter", body.openrouter)

    local results = {
        openrouter = {
            configured = true,
            healthy = openrouter_healthy,
            message = openrouter_message
        }
    }

    local openai_provided = body.openai and body.openai ~= ""
    if openai_provided then
        local openai_healthy, openai_message = test_provider_status("openai", body.openai)
        results.openai = {
            configured = true,
            healthy = openai_healthy,
            message = openai_message
        }
    else
        results.openai = {
            configured = false,
            healthy = false,
            message = "Not provided"
        }
    end

    -- Check if ALL provided keys are working
    local overall_success = results.openrouter.healthy
    if openai_provided then
        overall_success = overall_success and results.openai.healthy
    end

    -- Only set environment variables if ALL tests pass
    if overall_success then
        env.set("OPENROUTER_API_KEY", body.openrouter)
        if openai_provided then
            env.set("OPENAI_API_KEY", body.openai)
        end
    end

    local healthy_count = results.openrouter.healthy and 1 or 0
    local total_configured = 1

    if results.openai.configured then
        total_configured = total_configured + 1
        if results.openai.healthy then
            healthy_count = healthy_count + 1
        end
    end

    local summary = {
        string.format("OpenRouter: %s", results.openrouter.healthy and "✓ Connected" or "✗ " .. results.openrouter.message),
    }

    if results.openai.configured then
        table.insert(summary, string.format("OpenAI: %s", results.openai.healthy and "✓ Connected" or "✗ " .. results.openai.message))
    end

    local status_code = overall_success and http.STATUS.OK or http.STATUS.BAD_REQUEST

    res:set_status(status_code)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = overall_success,
        message = overall_success and "All providers connected successfully!" or "Provider setup failed",
        results = results,
        summary = summary,
        stats = {
            total_configured = total_configured,
            healthy_providers = healthy_count,
            has_embedding_support = results.openai and results.openai.healthy,
            has_advanced_models = results.openrouter.healthy
        }
    })
end

return {
    handler = handler
}