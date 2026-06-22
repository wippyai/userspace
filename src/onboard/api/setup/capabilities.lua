local http = require("http")
local json = require("json")
local security = require("security")
local env = require("env")
local http_client = require("http_client")
local api_error = require("api_error")

local function validate_credential_format(service, credential_type, value)
    if not value or value == "" then
        return false, "No " .. credential_type .. " provided"
    end

    local format_rules = {
        google_search = {
            api_key = {
                pattern = "^AIza[A-Za-z0-9_%-]+$",
                min_length = 25,
                error = "Google API key must start with 'AIza' and be at least 25 characters"
            },
            engine_id = {
                pattern = "^[a-z0-9]+$",
                min_length = 10,
                error = "Search Engine ID must be alphanumeric and at least 10 characters"
            }
        },
        google = {
            client_id = {
                pattern = "^[0-9]+-[a-zA-Z0-9]+%.apps%.googleusercontent%.com$",
                min_length = 20,
                error = "Google Client ID must be in format: numbers-string.apps.googleusercontent.com"
            },
            client_secret = {
                pattern = "^GOCSPX%-[A-Za-z0-9_%-]+$",
                min_length = 15,
                error = "Google Client Secret must start with 'GOCSPX-'"
            }
        },
        github = {
            client_id = {
                pattern = "^[A-Za-z0-9]+$",
                min_length = 10,
                error = "GitHub Client ID must be alphanumeric and at least 10 characters"
            },
            client_secret = {
                pattern = "^[a-f0-9]+$",
                min_length = 20,
                error = "GitHub Client Secret must be hexadecimal and at least 20 characters"
            }
        }
    }

    local service_rules = format_rules[service]
    if not service_rules then
        return false, "Unknown service: " .. service
    end

    local rule = service_rules[credential_type]
    if not rule then
        return false, "Unknown credential type: " .. credential_type
    end

    if #value < rule.min_length then
        return false, rule.error
    end

    if not string.match(value, rule.pattern) then
        return false, rule.error
    end

    local lower_value = string.lower(value)
    if string.find(lower_value, "test") or
       string.find(lower_value, "example") or
       string.find(lower_value, "your") or
       string.find(lower_value, "replace") then
        return false, "Invalid " .. credential_type .. " format"
    end

    return true, "Format valid"
end

local function test_google_search(api_key, engine_id)
    local valid_key, key_error = validate_credential_format("google_search", "api_key", api_key)
    if not valid_key then
        return false, key_error
    end

    local valid_id, id_error = validate_credential_format("google_search", "engine_id", engine_id)
    if not valid_id then
        return false, id_error
    end

    local test_url = string.format(
        "https://www.googleapis.com/customsearch/v1?key=%s&cx=%s&q=test&num=1",
        api_key, engine_id
    )

    local response, err = http_client.get(test_url, {
        timeout = 10
    })

    if err then
        return false, "Connection failed: " .. err
    end

    if response.status_code == 200 then
        return true, "Connected successfully"
    elseif response.status_code == 400 then
        return false, "Invalid Search Engine ID"
    elseif response.status_code == 403 then
        return false, "Invalid API key or quota exceeded"
    else
        return false, "API error: " .. response.status_code
    end
end

local function test_google_oauth(client_id, client_secret)
    local valid_id, id_error = validate_credential_format("google", "client_id", client_id)
    if not valid_id then
        return false, id_error
    end

    local valid_secret, secret_error = validate_credential_format("google", "client_secret", client_secret)
    if not valid_secret then
        return false, secret_error
    end

    return true, "Format valid"
end

local function test_github_oauth(client_id, client_secret)
    local valid_id, id_error = validate_credential_format("github", "client_id", client_id)
    if not valid_id then
        return false, id_error
    end

    local valid_secret, secret_error = validate_credential_format("github", "client_secret", client_secret)
    if not valid_secret then
        return false, secret_error
    end

    return true, "Format valid"
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
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.BAD_REQUEST, "Invalid JSON", err)
        return
    end

    local results = {}
    local overall_success = true
    local summary = {}

    if body.google_search then
        if body.google_search.api_key and body.google_search.engine_id then
            local search_success, search_message = test_google_search(
                body.google_search.api_key,
                body.google_search.engine_id
            )
            results.google_search = {
                configured = true,
                healthy = search_success,
                message = search_message
            }
            table.insert(summary, string.format("Web Search: %s",
                search_success and "✓ Connected" or "✗ " .. search_message))
            if not search_success then
                overall_success = false
            end
        else
            results.google_search = {
                configured = false,
                healthy = false,
                message = "API key and engine ID required"
            }
        end
    end

    if body.google then
        if body.google.client_id and body.google.client_secret then
            local google_success, google_message = test_google_oauth(
                body.google.client_id,
                body.google.client_secret
            )
            results.google = {
                configured = true,
                healthy = google_success,
                message = google_message
            }
            table.insert(summary, string.format("Google Integration: %s",
                google_success and "✓ Connected" or "✗ " .. google_message))
            if not google_success then
                overall_success = false
            end
        else
            results.google = {
                configured = false,
                healthy = false,
                message = "Client ID and secret required"
            }
        end
    end

    if body.github then
        if body.github.client_id and body.github.client_secret then
            local github_success, github_message = test_github_oauth(
                body.github.client_id,
                body.github.client_secret
            )
            results.github = {
                configured = true,
                healthy = github_success,
                message = github_message
            }
            table.insert(summary, string.format("GitHub Integration: %s",
                github_success and "✓ Connected" or "✗ " .. github_message))
            if not github_success then
                overall_success = false
            end
        else
            results.github = {
                configured = false,
                healthy = false,
                message = "Client ID and secret required"
            }
        end
    end

    if overall_success then
        if body.google_search and body.google_search.api_key and body.google_search.engine_id then
            env.set("userspace.webscout:google_search_api_key", body.google_search.api_key)
            env.set("userspace.webscout:google_search_engine_id", body.google_search.engine_id)
        end

        if body.google and body.google.client_id and body.google.client_secret then
            env.set("GOOGLE_CLIENT_ID", body.google.client_id)
            env.set("GOOGLE_CLIENT_SECRET", body.google.client_secret)
        end

        if body.github and body.github.client_id and body.github.client_secret then
            env.set("GITHUB_CLIENT_ID", body.github.client_id)
            env.set("GITHUB_CLIENT_SECRET", body.github.client_secret)
        end
    end

    local status_code = overall_success and http.STATUS.OK or http.STATUS.BAD_REQUEST
    res:set_status(status_code)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = overall_success,
        message = overall_success and "All capabilities configured successfully!" or "Capability configuration failed",
        results = results,
        summary = summary
    })
end

return {
    handler = handler
}