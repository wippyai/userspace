local ctx = require("ctx")
local env = require("env")
local http_client = require("http_client")
local json = require("json")
local logger = require("logger"):named("userspace.oauth.callback")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_STATE = "state parameter is required",
    MISSING_STORED_DATA = "stored_data is required",
    MISSING_TOKEN_ENDPOINT = "oauth_token_endpoint context is required",
    MISSING_CLIENT_ID = "oauth_client_id_env context is required",
    OAUTH_ERROR = "OAuth provider returned an error",
    TOKEN_EXCHANGE_FAILED = "Failed to exchange authorization code for token",
    USERINFO_FAILED = "Failed to retrieve user information"
}

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    -- Check for OAuth errors first
    if request_dto.error then
        logger:debug("OAuth provider error received", {
            error = request_dto.error,
            error_description = request_dto.error_description
        })
        return {
            success = false,
            error = VALIDATION_ERRORS.OAUTH_ERROR .. ": " .. request_dto.error
        }
    end

    -- Validate required fields
    if not request_dto.state or request_dto.state == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_STATE }
    end

    if not request_dto.stored_data or type(request_dto.stored_data) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_STORED_DATA }
    end

    if not request_dto.code or request_dto.code == "" then
        return { success = false, error = "Authorization code is required" }
    end

    -- Get required OAuth configuration from context
    local token_endpoint, err = ctx.get("oauth_token_endpoint")
    if err then
        return { success = false, error = "Failed to get token endpoint: " .. err }
    end
    if not token_endpoint or token_endpoint == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_TOKEN_ENDPOINT }
    end

    -- Get client ID from environment variable
    local client_id_env, err = ctx.get("oauth_client_id_env")
    if err then
        return { success = false, error = "Failed to get client ID environment variable name: " .. err }
    end
    if not client_id_env or client_id_env == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_CLIENT_ID }
    end

    local client_id, err = env.get(client_id_env)
    if err then
        return {
            success = false,
            error = "Failed to get client ID from environment variable " .. client_id_env .. ": " .. err
        }
    end
    if not client_id or client_id == "" then
        return {
            success = false,
            error = "Environment variable " .. client_id_env .. " is empty or not set"
        }
    end

    -- Check if we're using PKCE
    local use_pkce, err = ctx.get("oauth_use_pkce")
    if err then
        use_pkce = false
    else
        use_pkce = use_pkce or false
    end

    -- Get client secret from environment variable (completely optional)
    local client_secret = nil
    local has_client_secret = false

    -- Try to get client secret env var name - this can fail and that's OK
    local client_secret_env, err = ctx.get("oauth_client_secret_env")
    if client_secret_env and client_secret_env ~= "" then
        -- Only try to get the secret if the env var name is configured
        local env_secret, env_err = env.get(client_secret_env)
        if not env_err and env_secret and env_secret ~= "" then
            client_secret = env_secret
            has_client_secret = true
        end
        -- Don't error if env var is missing - just continue without secret
    end

    -- Validate authentication method: either client secret OR PKCE with code verifier
    if not has_client_secret and not (use_pkce and request_dto.stored_data.code_verifier) then
        return {
            success = false,
            error = "Either client_secret (via environment variable) or PKCE with code_verifier is required for token exchange"
        }
    end

    logger:debug("OAuth callback processing started", {
        token_endpoint = token_endpoint,
        client_id_env = client_id_env,
        has_client_secret = has_client_secret,
        use_pkce = use_pkce,
        has_code_verifier = request_dto.stored_data.code_verifier ~= nil,
        state = request_dto.state
    })

    -- Prepare token exchange request
    local token_request_body = {
        grant_type = "authorization_code",
        code = request_dto.code,
        redirect_uri = request_dto.stored_data.redirect_uri,
        client_id = client_id
    }

    -- Include client secret only if we have it
    if has_client_secret then
        token_request_body.client_secret = client_secret
    end

    -- Add PKCE code verifier if present (for public clients)
    if request_dto.stored_data.code_verifier then
        token_request_body.code_verifier = request_dto.stored_data.code_verifier
    end

    -- Convert to form data
    local form_data = {}
    for key, value in pairs(token_request_body) do
        table.insert(form_data, key .. "=" .. tostring(value))
    end
    local request_body = table.concat(form_data, "&")

    -- Exchange authorization code for access token
    local token_response, err = http_client.post(token_endpoint, {
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json"
        },
        body = request_body
    })

    if err then
        logger:debug("Token exchange HTTP request failed", { error = err })
        return { success = false, error = VALIDATION_ERRORS.TOKEN_EXCHANGE_FAILED .. ": " .. err }
    end

    if token_response.status_code >= 400 then
        logger:debug("Token exchange failed", {
            status_code = token_response.status_code,
            response_body = token_response.body
        })
        return {
            success = false,
            error = VALIDATION_ERRORS.TOKEN_EXCHANGE_FAILED ..
            ": HTTP " .. token_response.status_code .. " - " .. (token_response.body or "No response body")
        }
    end

    -- Parse token response
    local token_data, err = json.decode(token_response.body)
    if err then
        logger:debug("Failed to parse token response", {
            error = err,
            response_body = token_response.body
        })
        return { success = false, error = "Failed to parse token response: " .. err }
    end

    if not token_data.access_token then
        if token_data.error then
            logger:debug("OAuth provider returned error in token response", {
                error = token_data.error,
                error_description = token_data.error_description
            })
            return {
                success = false,
                error = "OAuth provider error: " ..
                token_data.error .. " - " .. (token_data.error_description or "No description")
            }
        end
        return { success = false, error = "No access token in response" }
    end

    -- Calculate token expiration timestamp
    local expires_at = nil
    if token_data.expires_in then
        expires_at = os.time() + token_data.expires_in
    end

    -- Initialize comprehensive OAuth connection context (OAuth-specific data only)
    local oauth_connection = {
        -- Token information
        access_token = token_data.access_token,
        token_type = token_data.token_type or "Bearer",
        expires_in = token_data.expires_in,
        expires_at = expires_at,
        scope = token_data.scope,
        refresh_token = token_data.refresh_token,

        -- Connection metadata
        scopes_granted = token_data.scope and table.concat({ token_data.scope }, " ") or nil,
        scopes_requested = request_dto.stored_data.scopes,
        redirect_uri = request_dto.stored_data.redirect_uri,
        created_at = os.time(),
        last_token_refresh = os.time(),

        -- Raw provider response for debugging
        provider_token_response = token_data,

        -- Connection status
        is_active = true,
        connection_state = "authenticated"
    }

    -- Initialize user context (user profile data only)
    local user_context = {
        provider_user_id = "unknown",
        email = nil,
        display_name = nil,
        username = nil,
        avatar_url = nil,
        first_name = nil,
        last_name = nil,
        locale = nil,
        provider_data = nil
    }

    logger:debug("Token exchange successful", {
        token_type = token_data.token_type,
        expires_in = token_data.expires_in,
        has_refresh_token = token_data.refresh_token ~= nil,
        scope = token_data.scope,
        auth_method = has_client_secret and "client_secret" or "pkce"
    })

    -- Get optional userinfo configuration
    local userinfo_endpoint, err = ctx.get("oauth_userinfo_endpoint")
    if err then
        userinfo_endpoint = nil
    end

    local userinfo_method, err = ctx.get("oauth_userinfo_method")
    if err then
        userinfo_method = "GET"
    else
        userinfo_method = userinfo_method or "GET"
    end

    local userinfo_auth_header, err = ctx.get("oauth_userinfo_auth_header")
    if err then
        userinfo_auth_header = true
    else
        -- Handle boolean values properly
        if userinfo_auth_header == nil then
            userinfo_auth_header = true
        end
    end

    -- Get user info if userinfo endpoint is configured
    if userinfo_endpoint and userinfo_endpoint ~= "" then
        -- Determine how to send the access token
        local userinfo_headers = {
            ["Accept"] = "application/json"
        }

        -- Default to sending in Authorization header
        if userinfo_auth_header ~= false then
            userinfo_headers["Authorization"] = "Bearer " .. token_data.access_token
        end

        local userinfo_url = userinfo_endpoint

        -- If not using auth header, add token as query parameter
        if userinfo_auth_header == false then
            userinfo_url = userinfo_url .. "?access_token=" .. token_data.access_token
        end

        local userinfo_response, err

        if userinfo_method == "POST" then
            userinfo_response, err = http_client.post(userinfo_url, {
                headers = userinfo_headers
            })
        else
            userinfo_response, err = http_client.get(userinfo_url, {
                headers = userinfo_headers
            })
        end

        if err then
            logger:debug("Failed to retrieve user information", {
                endpoint = userinfo_endpoint,
                error = err
            })
            oauth_connection.userinfo_error = err
        elseif userinfo_response.status_code >= 400 then
            logger:debug("User info request failed", {
                endpoint = userinfo_endpoint,
                status_code = userinfo_response.status_code,
                response_body = userinfo_response.body
            })
            oauth_connection.userinfo_error = "HTTP " ..
            userinfo_response.status_code .. ": " .. (userinfo_response.body or "")
        else
            -- Parse user info response
            local userinfo_data, err = json.decode(userinfo_response.body)
            if err then
                logger:debug("Failed to parse user info response", { error = err })
                oauth_connection.userinfo_error = "Failed to parse user info: " .. err
            else
                -- Store raw provider user data
                user_context.provider_data = userinfo_data

                -- Map common fields
                if userinfo_data.id then
                    user_context.provider_user_id = tostring(userinfo_data.id)
                elseif userinfo_data.sub then
                    user_context.provider_user_id = tostring(userinfo_data.sub)
                end

                if userinfo_data.email then
                    user_context.email = userinfo_data.email
                end

                if userinfo_data.name then
                    user_context.display_name = userinfo_data.name
                elseif userinfo_data.login then
                    user_context.display_name = userinfo_data.login
                end

                -- Include GitHub-specific fields
                if userinfo_data.login then
                    user_context.username = userinfo_data.login
                end

                if userinfo_data.avatar_url then
                    user_context.avatar_url = userinfo_data.avatar_url
                end

                -- Include Google-specific fields
                if userinfo_data.picture then
                    user_context.avatar_url = userinfo_data.picture
                end

                if userinfo_data.given_name then
                    user_context.first_name = userinfo_data.given_name
                end

                if userinfo_data.family_name then
                    user_context.last_name = userinfo_data.family_name
                end

                if userinfo_data.locale then
                    user_context.locale = userinfo_data.locale
                end

                logger:debug("User information retrieved successfully", {
                    provider_user_id = user_context.provider_user_id,
                    email = user_context.email,
                    display_name = user_context.display_name
                })
            end
        end
    end

    logger:debug("OAuth callback processing completed successfully")

    return {
        success = true,
        oauth_connection = oauth_connection,
        user_context = user_context,

        -- Also include raw token data for debugging
        token_data = token_data
    }
end

return { handle = handle }