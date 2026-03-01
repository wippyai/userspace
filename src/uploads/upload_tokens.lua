local crypto = require("crypto")
local base64 = require("base64")
local json = require("json")
local env = require("env")

-- Convert hex string to bytes
local function hex_decode(hex_str)
    if not hex_str or #hex_str % 2 ~= 0 then
        return nil, "Invalid hex string"
    end

    local bytes = ""
    for i = 1, #hex_str, 2 do
        local hex_byte = hex_str:sub(i, i + 1)
        local byte_val = tonumber(hex_byte, 16)
        if not byte_val then
            return nil, "Invalid hex character"
        end
        bytes = bytes .. string.char(byte_val)
    end
    return bytes
end

-- Get encryption key from environment
local function get_encryption_key()
    local key_hex = env.get("ENCRYPTION_KEY")
    if not key_hex then
        error("ENCRYPTION_KEY environment variable is required but not set")
    end

    local key, err = hex_decode(key_hex)
    if err then
        error("Failed to decode encryption key: " .. err)
    end

    if #key ~= 16 and #key ~= 24 and #key ~= 32 then
        error("Encryption key must be 16, 24, or 32 bytes after decoding, got " .. #key)
    end

    return key
end

-- Pack upload completion token from parameters
local function pack(params)
    if type(params) ~= "table" then
        return nil, "Parameters must be provided as a table"
    end

    if not params.function_id then return nil, "function_id is required" end
    if not params.actor_id then return nil, "actor_id is required" end
    if not params.actor_scope then return nil, "actor_scope is required" end

    local payload = {
        function_id = params.function_id,
        on_error_id = params.on_error_id,
        params = params.params,
        actor_id = params.actor_id,
        actor_scope = params.actor_scope,
        issued_at = os.time(),
    }

    local json_data, err = json.encode(payload)
    if err then
        return nil, "Failed to encode payload: " .. err
    end

    local encryption_key = get_encryption_key()

    local encrypted, err = crypto.encrypt.aes(json_data, encryption_key :: string)
    if err then
        return nil, "Encryption error: " .. err
    end

    return base64.encode(encrypted)
end

-- Unpack and validate upload completion token
local function unpack(token: string?)
    if not token then return nil, "No token provided" end

    local encrypted_data = base64.decode(token)
    if not encrypted_data then
        return nil, "Invalid token format"
    end

    local encryption_key = get_encryption_key()

    local json_data, err = crypto.decrypt.aes(encrypted_data, encryption_key :: string)
    if err then
        return nil, "Invalid upload token: " .. err
    end

    local payload, err = json.decode(json_data)
    if err then
        return nil, "Malformed token payload: " .. err
    end

    local current_time = os.time()
    local issued_at = payload.issued_at or 0
    local token_age = current_time - issued_at

    if token_age > 86400 then
        return nil, "Token expired"
    end

    return payload
end

return {
    pack = pack,
    unpack = unpack,
}
