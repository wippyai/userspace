local sql = require("sql")
local json = require("json")
local uuid = require("uuid")
local time = require("time")
local env = require("env")
local crypto = require("crypto")

-- Constants
local DB_RESOURCE = "app:db"
local CREDENTIALS_TABLE = "credentials_store"

-- Validation constants
local VALIDATION_ERRORS = {
    COMPONENT_ID_REQUIRED = "Component ID is required",
    CONNECTION_NAME_REQUIRED = "Connection name is required",
    CREDENTIALS_DATA_REQUIRED = "Credentials data is required",
    ENCRYPTION_KEY_MISSING = "ENCRYPTION_KEY environment variable not set"
}

local credentials_repo = {}

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

local function encrypt_credentials(credentials_data, key)
    if not credentials_data or type(credentials_data) ~= "table" then
        return nil, "Credentials data must be a table"
    end

    -- JSON encode first
    local json_data, err = json.encode(credentials_data)
    if err then
        return nil, "Failed to encode credentials to JSON: " .. err
    end

    -- Then encrypt
    local encrypted, err = crypto.encrypt.aes(json_data, key)
    if err then
        return nil, "Failed to encrypt credentials: " .. err
    end

    return encrypted
end

local function decrypt_credentials(encrypted_data, key)
    if not encrypted_data or encrypted_data == "" then
        return {}, nil
    end

    -- Decrypt first
    local decrypted, err = crypto.decrypt.aes(encrypted_data, key)
    if err then
        return nil, "Failed to decrypt credentials: " .. err
    end

    -- Then JSON decode
    local data, err = json.decode(decrypted)
    if err then
        return nil, "Failed to decode decrypted JSON: " .. err
    end

    return data
end

local function encode_metadata(metadata)
    if not metadata then
        return nil
    end

    if type(metadata) ~= "table" then
        return tostring(metadata)
    end

    local encoded, err = json.encode(metadata)
    if err then
        return nil, "Failed to encode metadata: " .. err
    end

    return encoded
end

local function decode_metadata(metadata_json)
    if not metadata_json or metadata_json == "" then
        return {}
    end

    local decoded, err = json.decode(metadata_json)
    if err then
        return {}
    end

    return decoded
end

local function get_current_timestamp()
    return time.now():format(time.RFC3339)
end

---------------------------
-- Repository Operations
---------------------------

-- Store credentials for a connection
-- @param component_id string UUID
-- @param connection_data table {connection_name, connection_description?, credentials, metadata?}
-- @return table {success, component_id, created_at, updated_at} | nil, error_string
function credentials_repo.store_credentials(component_id, connection_data)
    -- Validate inputs
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    if not connection_data or type(connection_data) ~= "table" then
        return nil, "Connection data is required and must be a table"
    end

    if not connection_data.connection_name or connection_data.connection_name == "" then
        return nil, VALIDATION_ERRORS.CONNECTION_NAME_REQUIRED
    end

    if not connection_data.credentials or type(connection_data.credentials) ~= "table" then
        return nil, VALIDATION_ERRORS.CREDENTIALS_DATA_REQUIRED
    end

    -- Get encryption key
    local encryption_key, err = get_encryption_key()
    if err then
        return nil, err
    end

    -- Encrypt credentials
    local encrypted_credentials, err = encrypt_credentials(connection_data.credentials, encryption_key)
    if err then
        return nil, "Failed to encrypt credentials: " .. err
    end

    -- Encode metadata
    local metadata_json = nil
    if connection_data.metadata then
        metadata_json, err = encode_metadata(connection_data.metadata)
        if err then
            return nil, err
        end
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    local timestamp = get_current_timestamp()
    local record_id = uuid.v4()

    -- Use UPSERT pattern - try update first, then insert if not exists
    local update_query = sql.builder.update(CREDENTIALS_TABLE)
        :set("connection_name", connection_data.connection_name)
        :set("connection_description", connection_data.connection_description or sql.as.null())
        :set("credentials_data", encrypted_credentials)
        :set("metadata", metadata_json or sql.as.null())
        :set("updated_at", timestamp)
        :where("component_id = ?", component_id)

    local update_executor = update_query:run_with(db)
    local update_result, err = update_executor:exec()

    if err then
        db:release()
        return nil, "Failed to update credentials: " .. err
    end

    -- If no rows were updated, insert new record
    if update_result.rows_affected == 0 then
        local insert_query = sql.builder.insert(CREDENTIALS_TABLE)
            :set_map({
                id = record_id,
                component_id = component_id,
                connection_name = connection_data.connection_name,
                connection_description = connection_data.connection_description or sql.as.null(),
                credentials_data = encrypted_credentials,
                metadata = metadata_json or sql.as.null(),
                created_at = timestamp,
                updated_at = timestamp
            })

        local insert_executor = insert_query:run_with(db)
        local insert_result, err = insert_executor:exec()

        if err then
            db:release()
            return nil, "Failed to insert credentials: " .. err
        end
    end

    db:release()

    return {
        component_id = component_id,
        success = true,
        created_at = timestamp,
        updated_at = timestamp
    }
end

-- Get credentials with connection metadata
-- @param component_id string UUID
-- @return table {component_id, connection_name, connection_description, credentials, metadata, created_at, updated_at} | nil, error_string
function credentials_repo.get_credentials(component_id)
    -- Validate inputs
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Query for credentials
    local query = sql.builder.select("*")
        :from(CREDENTIALS_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local results, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to query credentials: " .. err
    end

    if #results == 0 then
        return nil, "Credentials not found"
    end

    local record = results[1]

    -- Get encryption key
    local encryption_key, err = get_encryption_key()
    if err then
        return nil, err
    end

    -- Decrypt credentials
    local credentials, err = decrypt_credentials(tostring(record.credentials_data or ""), encryption_key)
    if err then
        return nil, "Failed to decrypt credentials: " .. err
    end

    -- Decode metadata
    local metadata = decode_metadata(tostring(record.metadata or ""))

    return {
        component_id = component_id,
        connection_name = record.connection_name,
        connection_description = record.connection_description,
        credentials = credentials,
        metadata = metadata,
        created_at = record.created_at,
        updated_at = record.updated_at
    }
end

-- Get connection metadata (no decryption)
-- @param component_id string UUID
-- @return table {component_id, connection_name, connection_description, metadata, created_at, updated_at} | nil, error_string
function credentials_repo.get_connection_metadata(component_id)
    -- Validate inputs
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
        "component_id", "connection_name", "connection_description",
        "metadata", "created_at", "updated_at"
    )
        :from(CREDENTIALS_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local results, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to query connection metadata: " .. err
    end

    if #results == 0 then
        return nil, "Connection not found"
    end

    local record = results[1]

    -- Decode metadata
    local metadata = decode_metadata(tostring(record.metadata or ""))

    return {
        component_id = record.component_id,
        connection_name = record.connection_name,
        connection_description = record.connection_description,
        metadata = metadata,
        created_at = record.created_at,
        updated_at = record.updated_at
    }
end

-- Delete credentials
-- @param component_id string UUID
-- @return table {success, component_id, deleted} | nil, error_string
function credentials_repo.delete_credentials(component_id)
    -- Validate inputs
    if not component_id or component_id == "" then
        return nil, VALIDATION_ERRORS.COMPONENT_ID_REQUIRED
    end

    -- Get database
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Delete credentials
    local query = sql.builder.delete(CREDENTIALS_TABLE)
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to delete credentials: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Credentials not found"
    end

    return {
        component_id = component_id,
        success = true,
        deleted = true
    }
end

return credentials_repo
