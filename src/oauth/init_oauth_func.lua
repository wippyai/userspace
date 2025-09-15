local ctx = require("ctx")
local env = require("env")
local hash = require("hash")
local crypto = require("crypto")
local base64 = require("base64")
local logger = require("logger"):named("userspace.oauth.init")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_REDIRECT_URI = "redirect_uri is required",
    MISSING_AUTHORIZATION_ENDPOINT = "oauth_authorization_endpoint context is required",
    MISSING_CLIENT_ID = "oauth_client_id_env context is required"
}

-- URL encode function using proper encoding
local function url_encode(str)
    if not str then
        return nil
    end

    -- Characters that don't need encoding (unreserved characters per RFC 3986)
    local function char_needs_encoding(char)
        local byte = string.byte(char)
        -- A-Z, a-z, 0-9, -, ., _, ~
        return not (
            (byte >= 65 and byte <= 90) or  -- A-Z
            (byte >= 97 and byte <= 122) or -- a-z
            (byte >= 48 and byte <= 57) or  -- 0-9
            byte == 45 or byte == 46 or     -- - .
            byte == 95 or byte == 126       -- _ ~
        )
    end

    return string.gsub(str, ".", function(char)
        if char_needs_encoding(char) then
            return string.format("%%%02X", string.byte(char))
        else
            return char
        end
    end)
end

-- Base64 URL-safe encoding
local function base64_url_encode(str)
    if not str then
        return nil
    end

    local encoded = base64.encode(str)
    if not encoded then
        return nil
    end

    -- Make URL-safe: replace + with -, / with _, remove padding =
    return encoded:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
end

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    -- Validate required fields
    if not request_dto.redirect_uri or request_dto.redirect_uri == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_REDIRECT_URI }
    end

    -- Get required OAuth configuration from context
    local authorization_endpoint, err = ctx.get("oauth_authorization_endpoint")
    if err then
        return { success = false, error = "Failed to get authorization endpoint: " .. err }
    end
    if not authorization_endpoint or authorization_endpoint == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_AUTHORIZATION_ENDPOINT }
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

    -- Get optional configuration values with defaults
    local use_pkce, err = ctx.get("oauth_use_pkce")
    if err then
        use_pkce = false
    else
        use_pkce = use_pkce or false
    end

    local pkce_method, err = ctx.get("oauth_pkce_method")
    if err then
        pkce_method = "S256"
    else
        pkce_method = pkce_method or "S256"
    end

    local response_type, err = ctx.get("oauth_response_type")
    if err then
        response_type = "code"
    else
        response_type = response_type or "code"
    end

    logger:debug("OAuth initialization started", {
        authorization_endpoint = authorization_endpoint,
        client_id_env = client_id_env,
        redirect_uri = request_dto.redirect_uri,
        scopes_count = #(request_dto.scopes or {}),
        use_pkce = use_pkce,
        pkce_method = pkce_method,
        response_type = response_type
    })

    -- Generate secure state parameter
    local state_token, err = crypto.random.string(32)
    if err then
        return { success = false, error = "Failed to generate state token: " .. err }
    end

    -- Prepare storage payload
    local storage_payload = {
        redirect_uri = request_dto.redirect_uri,
        scopes = request_dto.scopes or {},
        created_at = os.time()
    }

    -- Generate PKCE parameters if enabled
    local code_challenge = nil
    if use_pkce then
        local code_verifier, err = crypto.random.string(64,
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if err then
            return { success = false, error = "Failed to generate code verifier: " .. err }
        end

        -- Store code verifier in payload for callback
        storage_payload.code_verifier = code_verifier

        if pkce_method == "S256" then
            local challenge_raw, err = hash.sha256(code_verifier, true)
            if err then
                return { success = false, error = "Failed to generate code challenge: " .. err }
            end
            code_challenge = base64_url_encode(challenge_raw)
        else
            -- Plain method
            code_challenge = code_verifier
        end

        logger:debug("PKCE challenge generated", { method = pkce_method })
    end

    -- Build authorization URL parameters
    local url_params = {
        "client_id=" .. url_encode(client_id),
        "redirect_uri=" .. url_encode(request_dto.redirect_uri),
        "state=" .. url_encode(state_token)
    }

    -- Only add response_type if it's not empty (GitHub doesn't want this parameter)
    if response_type and response_type ~= "" then
        table.insert(url_params, 1, "response_type=" .. url_encode(response_type))
    end

    -- Add scopes if provided
    if request_dto.scopes and #request_dto.scopes > 0 then
        table.insert(url_params, "scope=" .. url_encode(table.concat(request_dto.scopes, " ")))
    end

    -- Add PKCE parameters if enabled
    if use_pkce and code_challenge then
        table.insert(url_params, "code_challenge=" .. url_encode(code_challenge))
        table.insert(url_params, "code_challenge_method=" .. url_encode(pkce_method))
    end

    -- Construct final authorization URL
    local authorization_url = authorization_endpoint
    if #url_params > 0 then
        authorization_url = authorization_url .. "?" .. table.concat(url_params, "&")
    end

    logger:debug("OAuth initialization completed", {
        state_token = state_token,
        expires_in = 600
    })

    -- Return success response with storage payload for upper level to handle
    return {
        success = true,
        authorization_url = authorization_url,
        state_token = state_token,
        storage_payload = storage_payload,
        expires_in = 600 -- Suggest 10 minute expiration
    }
end

return { handle = handle }
