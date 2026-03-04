local sql = require("sql")
local json = require("json")
local uuid = require("uuid")
local time = require("time")
local env = require("env")
local crypto = require("crypto")

-- Constants
local DB_RESOURCE = "app:db"
local OAUTH_TABLE = "oauth_connections"

-- Validation constants
local VALIDATION_ERRORS = {
    COMPONENT_ID_REQUIRED = "Component ID is required",
    CONNECTION_DATA_REQUIRED = "Connection data is required",
    PROVIDER_REQUIRED = "Provider is required",
    CONNECTION_NAME_REQUIRED = "Connection name is required",
    TOKENS_REQUIRED = "Tokens are required",
    ENCRYPTION_KEY_MISSING = "ENCRYPTION_KEY environment variable not set",
    INVALID_EXPIRES_AT = "expires_at must be a number"
}

local oauth_repo = {}

---------------------------
-- Helper Functions
---------------------------

local function get_db()
    local db, err = sql.get(DB_RESOURCE)
    if err then
        return nil, "Failed to connect to database: " .. err
    end
    return db
end

local function get_encryption_key()
    local key, err = env.get("ENCRYPTION_KEY")
    if err then
        return nil, "Failed to get encryption key: " .. err
    end
    if not key or key == "" then
        return nil, VALIDATION_ERRORS.ENCRYPTION_KEY_MISSING
    end

    -- Decode hex string to binary bytes (64 chars = 32 bytes)
    if #key ~= 64 then
        return nil, "ENCRYPTION_KEY must be 64 hex characters (32 bytes)"
    end

    local binary_key = ""
    for i = 1, #key, 2 do
        local hex_byte = key:sub(i, i + 1)
        local byte = tonumber(hex_byte, 16)
        if not byte then
            return nil, "ENCRYPTION_KEY contains invalid hex characters"
        end
        binary_key = binary_key .. string.char(byte)
    end

    return binary_key
end

local function encrypt_oauth_data(oauth_data, key)
    if not oauth_data or type(oauth_data) ~= "table" then
        return nil, "OAuth data must be a table"
    end

    -- JSON encode first
    local json_data, err = json.encode(oauth_data)
    if err then
        return nil, "Failed to encode OAuth data to JSON: " .. err
    end

    -- Then encrypt
    local encrypted, err = crypto.encrypt.aes(json_data, key)
    if err then
        return nil, "Failed to encrypt OAuth data: " .. err
    end

    return encrypted
end

local function decrypt_oauth_data(encrypted_data, key)
    if not encrypted_data or encrypted_data == "" then
        return {}, nil
    end

    -- Decrypt first
    local decrypted, err = crypto.decrypt.aes(encrypted_data, key)
    if err then
        return nil, "Failed to decrypt OAuth data: " .. err
    end

    -- Then JSON decode
    local data, err = json.decode(decrypted)
    if err then
        return nil, "Failed to decode decrypted JSON: " .. err
    end

    return data
end

-- Encrypt just the access token for optimized storage
local function encrypt_access_token(access_token, key)
    if not access_token or access_token == "" then
        return nil, nil -- No token to encrypt
    end

    local encrypted, err = crypto.encrypt.aes(access_token, key)
    if err then
        return nil, "Failed to encrypt access token: " .. err
    end

    return encrypted
end

-- Decrypt just the access token
local function decrypt_access_token(encrypted_token, key)
    if not encrypted_token or encrypted_token == "" then
        return nil, nil -- No token to decrypt
    end

    local decrypted, err = crypto.decrypt.aes(encrypted_token, key)
    if err then
        return nil, "Failed to decrypt access token: " .. err
    end

    return decrypted
end

local function get_current_timestamp()
    return time.now():format(time.RFC3339)
end

---------------------------
-- Repository Interface
---------------------------

-- Create new OAuth connection
-- @param component_id string UUID
-- @param connection_data table {provider, connection_name, connection_description?, schedule_id?, scopes_granted?, tokens, user_profile?, client_credentials?, provider_specific?, oauth_flow?}
-- @return table {success, component_id, created_at} | nil, error_string
function oauth_repo.create_connection(component_id, connection_data)
    -- Validate inputs
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end
    if not connection_data or type(connection_data) ~= "table" then
        return nil, VALIDATION_ERRORS.CONNECTION_DATA_REQUIRED
    end
    if not connection_data.provider or connection_data.provider == "" then
        return nil, VALIDATION_ERRORS.PROVIDER_REQUIRED
    end
    if not connection_data.connection_name or connection_data.connection_name == "" then
        return nil, VALIDATION_ERRORS.CONNECTION_NAME_REQUIRED
    end
    if not connection_data.tokens or type(connection_data.tokens) ~= "table" then
        return nil, VALIDATION_ERRORS.TOKENS_REQUIRED
    end

    -- Get encryption key
    local encryption_key, err = get_encryption_key()
    if err then
        return nil, err
    end

    -- Prepare sensitive data (encrypted)
    local oauth_data = {
        tokens = connection_data.tokens,
        client_credentials = connection_data.client_credentials or {},
        user_profile = connection_data.user_profile or {},
        provider_specific = connection_data.provider_specific or {},
        oauth_flow = connection_data.oauth_flow or {}
    }

    -- Encrypt sensitive data
    local encrypted_data, err = encrypt_oauth_data(oauth_data, encryption_key)
    if err then
        return nil, "Failed to encrypt OAuth data: " .. err
    end

    -- Encrypt access token separately for optimized access
    local access_token_encrypted, err = encrypt_access_token(connection_data.tokens.access_token :: string, encryption_key)
    if err then
        return nil, "Failed to encrypt access token: " .. err
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    local timestamp = get_current_timestamp()
    local record_id = uuid.v4()

    -- Insert connection
    local query = sql.builder.insert(OAUTH_TABLE)
        :set_map({
            id = record_id,
            component_id = component_id,
            provider = connection_data.provider,
            connection_name = connection_data.connection_name,
            connection_description = connection_data.connection_description or sql.as.null(),
            schedule_id = connection_data.schedule_id or sql.as.null(),
            scopes_granted = connection_data.scopes_granted or sql.as.null(),
            connection_state = connection_data.connection_state or "active",
            token_type = connection_data.token_type or "Bearer",
            expires_at = connection_data.expires_at or sql.as.null(),
            refresh_expires_at = connection_data.refresh_expires_at or sql.as.null(),
            access_token_encrypted = access_token_encrypted or sql.as.null(),
            oauth_data_encrypted = encrypted_data,
            created_at = timestamp,
            updated_at = timestamp
        })

    local executor = query:run_with(db)
    local result, err = executor:exec()
    db:release()

    if err then
        return nil, "Failed to insert OAuth connection: " .. err
    end

    return {
        success = true,
        component_id = component_id,
        created_at = timestamp
    }
end

-- Get complete OAuth connection with decrypted data
-- @param component_id string UUID
-- @return table {id, component_id, provider, connection_name, schedule_id, tokens, user_profile, ...} | nil, error_string
function oauth_repo.get_connection(component_id)
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Query connection
    local query = sql.builder.select("*")
        :from(OAUTH_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to query OAuth connection: " .. err
    end

    if #results == 0 then
        return nil, "OAuth connection not found"
    end

    local connection = results[1]

    -- Get encryption key
    local encryption_key, err = get_encryption_key()
    if err then
        return nil, err
    end

    -- Decrypt sensitive data
    local oauth_data, err = decrypt_oauth_data(connection.oauth_data_encrypted :: string, encryption_key)
    if err then
        return nil, "Failed to decrypt OAuth data: " .. err
    end

    -- Return complete connection
    return {
        id = connection.id,
        component_id = connection.component_id,
        provider = connection.provider,
        connection_name = connection.connection_name,
        connection_description = connection.connection_description,
        schedule_id = connection.schedule_id,
        scopes_granted = connection.scopes_granted,
        connection_state = connection.connection_state,
        token_type = connection.token_type,
        expires_at = connection.expires_at,
        refresh_expires_at = connection.refresh_expires_at,
        created_at = connection.created_at,
        updated_at = connection.updated_at,
        last_token_refresh = connection.last_token_refresh,
        -- Decrypted data
        tokens = oauth_data.tokens or {},
        client_credentials = oauth_data.client_credentials or {},
        user_profile = oauth_data.user_profile or {},
        provider_specific = oauth_data.provider_specific or {},
        oauth_flow = oauth_data.oauth_flow or {}
    }
end

-- Get connection metadata with raw token expiration (no decryption)
-- @param component_id string UUID
-- @return table {id, provider, connection_name, schedule_id, scopes_granted, expires_at, connection_state, ...} | nil, error_string
function oauth_repo.get_connection_metadata(component_id)
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Query only metadata fields (no encrypted data)
    local query = sql.builder.select(
        "id", "component_id", "provider", "connection_name", "connection_description",
        "schedule_id", "scopes_granted", "connection_state", "token_type",
        "expires_at", "refresh_expires_at", "created_at", "updated_at", "last_token_refresh"
    )
        :from(OAUTH_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to query OAuth connection metadata: " .. err
    end

    if #results == 0 then
        return nil, "OAuth connection not found"
    end

    return results[1]
end

-- Get access token with raw expiration data (optimized operation)
-- @param component_id string UUID
-- @return table {access_token, expires_at} | nil, error_string
function oauth_repo.get_access_token(component_id)
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Query connection with optimized access token field only
    local query = sql.builder.select("access_token_encrypted", "expires_at")
        :from(OAUTH_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to query OAuth connection: " .. err
    end

    if #results == 0 then
        return nil, "OAuth connection not found"
    end

    local connection = results[1]

    -- Get encryption key
    local encryption_key, err = get_encryption_key()
    if err then
        return nil, err
    end

    -- Decrypt optimized access token
    if not connection.access_token_encrypted or connection.access_token_encrypted == "" then
        return nil, "No access token available"
    end

    local access_token, err = decrypt_access_token(connection.access_token_encrypted :: string, encryption_key)
    if err then
        return nil, "Failed to decrypt access token: " .. err
    end

    if not access_token or access_token == "" then
        return nil, "No access token available"
    end

    return {
        access_token = access_token,
        expires_at = connection.expires_at
    }
end

-- Update tokens after refresh
-- @param component_id string UUID
-- @param tokens table {access_token, refresh_token?, id_token?, scope?}
-- @param expires_at number? unix_timestamp
-- @return table {success, updated_at} | nil, error_string
function oauth_repo.update_tokens(component_id, tokens, expires_at)
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end
    if not tokens or type(tokens) ~= "table" then
        return nil, VALIDATION_ERRORS.TOKENS_REQUIRED
    end
    if expires_at and type(expires_at) ~= "number" then
        return nil, VALIDATION_ERRORS.INVALID_EXPIRES_AT
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Get current connection
    local query = sql.builder.select("oauth_data_encrypted")
        :from(OAUTH_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local results, err = executor:query()
    if err then
        db:release()
        return nil, "Failed to query OAuth connection: " .. err
    end

    if #results == 0 then
        db:release()
        return nil, "OAuth connection not found"
    end

    local connection = results[1]

    -- Get encryption key
    local encryption_key, err = get_encryption_key()
    if err then
        db:release()
        return nil, err
    end

    -- Decrypt current data
    local oauth_data, err = decrypt_oauth_data(connection.oauth_data_encrypted :: string, encryption_key)
    if err then
        db:release()
        return nil, "Failed to decrypt OAuth data: " .. err
    end

    -- Update tokens
    oauth_data.tokens = oauth_data.tokens or {}
    for key, value in pairs(tokens) do
        oauth_data.tokens[key] = value
    end

    -- Re-encrypt data
    local encrypted_data, err = encrypt_oauth_data(oauth_data, encryption_key)
    if err then
        db:release()
        return nil, "Failed to encrypt updated OAuth data: " .. err
    end

    -- Encrypt the access token separately for optimized access
    local access_token_encrypted, err = encrypt_access_token(tokens.access_token :: string, encryption_key)
    if err then
        db:release()
        return nil, "Failed to encrypt access token: " .. err
    end

    -- Update database
    local timestamp = get_current_timestamp()
    local updates = {
        oauth_data_encrypted = encrypted_data,
        access_token_encrypted = access_token_encrypted or sql.as.null(),
        last_token_refresh = timestamp,
        updated_at = timestamp
    }

    if expires_at then
        updates.expires_at = expires_at
    end

    local update_query = sql.builder.update(OAUTH_TABLE)
        :set_map(updates)
        :where("component_id = ?", component_id)

    local update_executor = update_query:run_with(db)
    local result, err = update_executor:exec()
    db:release()

    if err then
        return nil, "Failed to update OAuth connection: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "OAuth connection not found"
    end

    return {
        success = true,
        updated_at = timestamp
    }
end

-- Update complete OAuth connection (for re-authorization and comprehensive updates)
-- @param component_id string UUID
-- @param connection_data table {provider?, connection_name?, connection_description?, scopes_granted?, connection_state?, token_type?, expires_at?, refresh_expires_at?, tokens?, user_profile?, client_credentials?, provider_specific?, oauth_flow?}
-- @return table {success, updated_at} | nil, error_string
function oauth_repo.update_connection(component_id, connection_data)
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end
    if not connection_data or type(connection_data) ~= "table" then
        return nil, VALIDATION_ERRORS.CONNECTION_DATA_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Get current connection in a transaction-safe way
    local query = sql.builder.select("oauth_data_encrypted")
        :from(OAUTH_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local results, err = executor:query()
    if err then
        db:release()
        return nil, "Failed to query OAuth connection: " .. err
    end

    if #results == 0 then
        db:release()
        return nil, "OAuth connection not found"
    end

    local connection = results[1]

    -- Get encryption key
    local encryption_key, err = get_encryption_key()
    if err then
        db:release()
        return nil, err
    end

    -- Decrypt current OAuth data
    local oauth_data, err = decrypt_oauth_data(connection.oauth_data_encrypted :: string, encryption_key)
    if err then
        db:release()
        return nil, "Failed to decrypt OAuth data: " .. err
    end

    -- Update nested encrypted data fields (merge with existing)
    if connection_data.tokens then
        oauth_data.tokens = oauth_data.tokens or {}
        for key, value in pairs(connection_data.tokens) do
            oauth_data.tokens[key] = value
        end
    end

    if connection_data.user_profile then
        oauth_data.user_profile = connection_data.user_profile
    end

    if connection_data.client_credentials then
        oauth_data.client_credentials = connection_data.client_credentials
    end

    if connection_data.provider_specific then
        oauth_data.provider_specific = connection_data.provider_specific
    end

    if connection_data.oauth_flow then
        oauth_data.oauth_flow = connection_data.oauth_flow
    end

    -- Re-encrypt OAuth data
    local encrypted_data, err = encrypt_oauth_data(oauth_data, encryption_key)
    if err then
        db:release()
        return nil, "Failed to encrypt updated OAuth data: " .. err
    end

    -- Encrypt access token separately if provided
    local access_token_encrypted = nil
    if connection_data.tokens and connection_data.tokens.access_token then
        access_token_encrypted, err = encrypt_access_token(connection_data.tokens.access_token :: string, encryption_key)
        if err then
            db:release()
            return nil, "Failed to encrypt access token: " .. err
        end
    end

    -- Prepare update fields
    local timestamp = get_current_timestamp()
    local updates = {
        oauth_data_encrypted = encrypted_data,
        last_token_refresh = timestamp,
        updated_at = timestamp
    }

    -- Update metadata fields if provided (these are stored unencrypted for querying)
    if connection_data.provider and connection_data.provider ~= "" then
        updates.provider = connection_data.provider
    end

    if connection_data.connection_name and connection_data.connection_name ~= "" then
        updates.connection_name = connection_data.connection_name
    end

    if connection_data.connection_description ~= nil then
        updates.connection_description = connection_data.connection_description ~= "" and connection_data.connection_description or sql.as.null()
    end

    if connection_data.scopes_granted then
        updates.scopes_granted = connection_data.scopes_granted
    end

    if connection_data.connection_state then
        updates.connection_state = connection_data.connection_state
    end

    if connection_data.token_type then
        updates.token_type = connection_data.token_type
    end

    if connection_data.expires_at then
        updates.expires_at = connection_data.expires_at
    end

    if connection_data.refresh_expires_at then
        updates.refresh_expires_at = connection_data.refresh_expires_at
    end

    if connection_data.schedule_id ~= nil then
        updates.schedule_id = connection_data.schedule_id ~= "" and connection_data.schedule_id or sql.as.null()
    end

    if access_token_encrypted then
        updates.access_token_encrypted = access_token_encrypted
    end

    -- Execute update in single transaction
    local update_query = sql.builder.update(OAUTH_TABLE)
        :set_map(updates)
        :where("component_id = ?", component_id)

    local update_executor = update_query:run_with(db)
    local result, err = update_executor:exec()
    db:release()

    if err then
        return nil, "Failed to update OAuth connection: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "OAuth connection not found"
    end

    return {
        success = true,
        updated_at = timestamp
    }
end

-- Update schedule_id for a connection
-- @param component_id string UUID
-- @param schedule_id string UUID or nil
-- @return table {success, updated_at} | nil, error_string
function oauth_repo.update_schedule_id(component_id, schedule_id)
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    local timestamp = get_current_timestamp()

    -- Update schedule_id
    local query = sql.builder.update(OAUTH_TABLE)
        :set_map({
            schedule_id = schedule_id or sql.as.null(),
            updated_at = timestamp
        })
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local result, err = executor:exec()
    db:release()

    if err then
        return nil, "Failed to update schedule_id: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "OAuth connection not found"
    end

    return {
        success = true,
        updated_at = timestamp
    }
end

-- List connections by provider (metadata only)
-- @param provider_name string
-- @return table[] array_of_connection_metadata | nil, error_string
function oauth_repo.list_by_provider(provider_name)
    if not provider_name or provider_name == "" then
        return nil, "Provider name is required"
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Query only metadata, no encrypted data
    local query = sql.builder.select(
        "id", "component_id", "provider", "connection_name", "connection_description",
        "schedule_id", "scopes_granted", "connection_state", "token_type",
        "expires_at", "refresh_expires_at", "created_at", "updated_at"
    )
        :from(OAUTH_TABLE)
        :where("provider = ?", provider_name)
        :order_by("created_at DESC")

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to list OAuth connections: " .. err
    end

    return results
end

-- List connections by schedule_id (metadata only)
-- @param schedule_id string UUID
-- @return table[] array_of_connection_metadata | nil, error_string
function oauth_repo.list_by_schedule_id(schedule_id)
    if not schedule_id or schedule_id == "" then
        return nil, "Schedule ID is required"
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Query only metadata, no encrypted data
    local query = sql.builder.select(
        "id", "component_id", "provider", "connection_name", "connection_description",
        "schedule_id", "scopes_granted", "connection_state", "token_type",
        "expires_at", "refresh_expires_at", "created_at", "updated_at"
    )
        :from(OAUTH_TABLE)
        :where("schedule_id = ?", schedule_id)
        :order_by("created_at DESC")

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to list OAuth connections by schedule: " .. err
    end

    return results
end

-- Delete OAuth connection
-- @param component_id string UUID
-- @return table {success, deleted} | nil, error_string
function oauth_repo.delete_connection(component_id)
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Delete connection
    local query = sql.builder.delete(OAUTH_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local result, err = executor:exec()
    db:release()

    if err then
        return nil, "Failed to delete OAuth connection: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "OAuth connection not found"
    end

    return {
        success = true,
        deleted = true
    }
end

-- Disable connection (soft delete)
-- @param component_id string UUID
-- @return table {success, updated_at} | nil, error_string
function oauth_repo.disable_connection(component_id)
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    local timestamp = get_current_timestamp()

    -- Update connection state
    local query = sql.builder.update(OAUTH_TABLE)
        :set_map({
            connection_state = "disabled",
            updated_at = timestamp
        })
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local result, err = executor:exec()
    db:release()

    if err then
        return nil, "Failed to disable OAuth connection: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "OAuth connection not found"
    end

    return {
        success = true,
        updated_at = timestamp
    }
end

return oauth_repo