local ctx = require("ctx")
local env = require("env")
local http_client = require("http_client")
local json = require("json")
local logger = require("logger"):named("userspace.oauth.refresh")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_REFRESH_TOKEN = "refresh_token is required",
    MISSING_TOKEN_ENDPOINT = "oauth_token_endpoint context is required",
    MISSING_CLIENT_ID = "oauth_client_id_env context is required",
    TOKEN_REFRESH_FAILED = "Failed to refresh access token"
}

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return {
            success = false,
            error = VALIDATION_ERRORS.INVALID_REQUEST,
            response_received = false
        }
    end

    -- Validate required fields
    if not request_dto.refresh_token or request_dto.refresh_token == "" then
        return {
            success = false,
            error = VALIDATION_ERRORS.MISSING_REFRESH_TOKEN,
            response_received = false
        }
    end

    -- Get required OAuth configuration from context
    local token_endpoint, err = ctx.get("oauth_token_endpoint")
    if err then
        return {
            success = false,
            error = "Failed to get token endpoint: " .. err,
            response_received = false
        }
    end
    if not token_endpoint or token_endpoint == "" then
        return {
            success = false,
            error = VALIDATION_ERRORS.MISSING_TOKEN_ENDPOINT,
            response_received = false
        }
    end

    -- Get client ID from environment variable
    local client_id_env, err = ctx.get("oauth_client_id_env")
    if err then
        return {
            success = false,
            error = "Failed to get client ID environment variable name: " .. err,
            response_received = false
        }
    end
    if not client_id_env or client_id_env == "" then
        return {
            success = false,
            error = VALIDATION_ERRORS.MISSING_CLIENT_ID,
            response_received = false
        }
    end

    local client_id, err = env.get(client_id_env :: string)
    if err then
        return {
            success = false,
            error = "Failed to get client ID from environment variable " .. client_id_env .. ": " .. err,
            response_received = false
        }
    end
    if not client_id or client_id == "" then
        return {
            success = false,
            error = "Environment variable " .. client_id_env .. " is empty or not set",
            response_received = false
        }
    end

    -- Get client secret from environment variable (optional)
    local client_secret = nil
    local client_secret_env, err = ctx.get("oauth_client_secret_env")
    if client_secret_env and client_secret_env ~= "" then
        local env_secret, env_err = env.get(client_secret_env :: string)
        if not env_err and env_secret and env_secret ~= "" then
            client_secret = env_secret
        end
    end

    logger:debug("OAuth token refresh started", {
        token_endpoint = token_endpoint,
        client_id_env = client_id_env,
        has_client_secret = client_secret ~= nil
    })

    -- Prepare token refresh request
    local token_request_body = {
        grant_type = "refresh_token",
        refresh_token = request_dto.refresh_token,
        client_id = client_id
    }

    -- Include client secret if available
    if client_secret then
        token_request_body.client_secret = client_secret
    end

    -- Convert to form data
    local form_data = {}
    for key, value in pairs(token_request_body) do
        table.insert(form_data, key .. "=" .. tostring(value))
    end
    local request_body = table.concat(form_data, "&")

    -- Make token refresh request
    local token_response, err = http_client.post(token_endpoint :: string, {
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json"
        },
        body = request_body
    })

    if err then
        logger:debug("Token refresh HTTP request failed", { error = err })
        return {
            success = false,
            error = VALIDATION_ERRORS.TOKEN_REFRESH_FAILED .. ": " .. err,
            response_received = false,
            transient = true  -- network error, refresh_token may still be valid
        }
    end

    local response_received = true
    local status_code = token_response.status_code

    if status_code >= 400 then
        -- 5xx (server error) and 429 (rate limit) are transient. The
        -- refresh_token has not been rejected; the provider just couldn't
        -- answer right now. 4xx other than 429 are final — invalid_grant,
        -- invalid_client, unauthorized — retrying will not change the answer.
        local transient = status_code >= 500 or status_code == 429

        logger:debug("Token refresh failed", {
            status_code = status_code,
            response_body = token_response.body,
            transient = transient
        })
        return {
            success = false,
            error = VALIDATION_ERRORS.TOKEN_REFRESH_FAILED ..
                ": HTTP " .. status_code .. " - " .. (token_response.body or "No response body"),
            response_received = response_received,
            status_code = status_code,
            transient = transient
        }
    end

    -- Parse token response
    local token_data, err = json.decode(token_response.body :: string)
    if err then
        logger:debug("Failed to parse token refresh response", {
            error = err,
            response_body = token_response.body
        })
        -- 200-with-unparseable-body usually means an intermediary (CDN, proxy)
        -- intercepted the response, not that the refresh_token is bad.
        return {
            success = false,
            error = "Failed to parse token response: " .. err,
            response_received = response_received,
            status_code = status_code,
            transient = true
        }
    end

    if not token_data.access_token then
        if token_data.error then
            logger:debug("OAuth provider returned error in refresh response", {
                error = token_data.error,
                error_description = token_data.error_description
            })
            -- Provider explicitly rejected the refresh_token. invalid_grant /
            -- invalid_client / unauthorized_client mean the credential is dead;
            -- the user must re-authorize. server_error / temporarily_unavailable
            -- may resolve on retry.
            local provider_error = token_data.error
            local transient = provider_error == "server_error"
                or provider_error == "temporarily_unavailable"
            return {
                success = false,
                error = "OAuth provider error: " ..
                    provider_error .. " - " .. (token_data.error_description or "No description"),
                response_received = response_received,
                status_code = status_code,
                transient = transient,
                provider_error = provider_error
            }
        end
        return {
            success = false,
            error = "No access token in refresh response",
            response_received = response_received,
            status_code = status_code,
            transient = false
        }
    end

    logger:debug("Token refresh successful", {
        token_type = token_data.token_type,
        expires_in = token_data.expires_in,
        has_new_refresh_token = token_data.refresh_token ~= nil,
        scope = token_data.scope
    })

    -- Return simple token response (let caller handle timestamps, storage, etc.)
    return {
        success = true,
        access_token = token_data.access_token,
        refresh_token = token_data.refresh_token, -- May be nil if provider doesn't rotate
        token_type = token_data.token_type or "Bearer",
        expires_in = token_data.expires_in,
        scope = token_data.scope,
        response_received = response_received
    }
end

return { handle = handle }