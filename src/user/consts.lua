local env = require("env")

local consts = {
    -- Environment variable IDs
    ENV_IDS = {
        DATABASE_RESOURCE = "userspace.user.env:database_resource",
        ADMIN_GROUP_ID = "userspace.user.env:admin_group_id",
        DEFAULT_GROUP_ID = "userspace.user.env:default_group_id",
        ADMIN_INIT_ENABLED = "userspace.user.env:admin_init_enabled",
        TOKEN_EXPIRATION = "userspace.user.env:token_expiration"
    },

    -- Internal Resource IDs
    RESOURCES = {
        TOKEN_STORE = "userspace.user.security:tokens"
    },

    -- User Status Constants
    USER_STATUS = {
        ACTIVE = "active",
        INACTIVE = "inactive",
        SUSPENDED = "suspended",
        PENDING = "pending"
    },

    -- Default Values
    DEFAULTS = {
        USER_STATUS = "active",
        ADMIN_INIT_ENABLED = true,
        ADMIN_USERNAME_PREFIX = "admin",
        PASSWORD_LENGTH = 16,
        USERNAME_LENGTH = 8
    },

    -- Validation Limits
    LIMITS = {
        MAX_EMAIL_LENGTH = 255,
        MAX_FULL_NAME_LENGTH = 200,
        MIN_PASSWORD_LENGTH = 8,
        MAX_PASSWORD_LENGTH = 128
    },

    -- Validation Sets
    VALID_VALUES = {
        USER_STATUS = {
            ["active"] = true,
            ["inactive"] = true,
            ["suspended"] = true,
            ["pending"] = true
        }
    },

    -- Error Messages
    ERROR = {
        -- General errors
        MISSING_REQUIRED_FIELD = "Missing required field: ",
        INVALID_FIELD_VALUE = "Invalid value for field: ",

        -- User errors
        USER_NOT_FOUND = "User not found",
        USER_ALREADY_EXISTS = "User already exists",
        INVALID_EMAIL_FORMAT = "Invalid email format",
        INVALID_PASSWORD = "Invalid password",
        INVALID_USER_STATUS = "Invalid user status",

        -- Authentication errors
        AUTHENTICATION_FAILED = "Authentication failed",
        INSUFFICIENT_PERMISSIONS = "Insufficient permissions",
        TOKEN_CREATION_FAILED = "Failed to create authentication token",

        -- Database errors
        DB_CONNECTION_FAILED = "Failed to connect to database",
        DB_OPERATION_FAILED = "Database operation failed",

        -- Group errors
        GROUP_NOT_FOUND = "Security group not found",
        GROUP_ASSIGNMENT_FAILED = "Failed to assign user to group"
    }
}

-- Get database resource
function consts.get_db_resource()
    local db_resource, _ = env.get(consts.ENV_IDS.DATABASE_RESOURCE)
    return db_resource
end

-- Load configuration from environment variables
function consts.get_config()
    local database_resource, _ = env.get(consts.ENV_IDS.DATABASE_RESOURCE)
    local admin_group_id, _ = env.get(consts.ENV_IDS.ADMIN_GROUP_ID)
    local default_group_id, _ = env.get(consts.ENV_IDS.DEFAULT_GROUP_ID)
    local admin_init_enabled, _ = env.get(consts.ENV_IDS.ADMIN_INIT_ENABLED)
    local token_expiration, _ = env.get(consts.ENV_IDS.TOKEN_EXPIRATION)

    return {
        -- Database configuration
        database_resource = database_resource,
        -- User configuration
        admin_group_id = admin_group_id,
        default_group_id = default_group_id,
        admin_init_enabled = admin_init_enabled == "true" or consts.DEFAULTS.ADMIN_INIT_ENABLED,
        -- Security configuration
        token_store = consts.RESOURCES.TOKEN_STORE,
        token_expiration = token_expiration
    }
end

-- Validate email format
function consts.validate_email(email)
    if not email or type(email) ~= "string" then
        return false, "Email must be a string"
    end

    if #email > consts.LIMITS.MAX_EMAIL_LENGTH then
        return false, "Email exceeds maximum length"
    end

    -- Basic email validation pattern
    local pattern = "^[%w%._%-%+]+@[%w%.%-]+%.%a%a+$"
    if not string.match(email, pattern) then
        return false, "Invalid email format"
    end

    return true
end

-- Validate user status
function consts.validate_user_status(status)
    if not status then
        return true -- Allow nil/empty for default
    end

    if not consts.VALID_VALUES.USER_STATUS[status] then
        return false, "Invalid user status: " .. tostring(status)
    end

    return true
end

-- Validate password strength
function consts.validate_password(password)
    if not password or type(password) ~= "string" then
        return false, "Password must be a string"
    end

    if #password < consts.LIMITS.MIN_PASSWORD_LENGTH then
        return false, "Password must be at least " .. consts.LIMITS.MIN_PASSWORD_LENGTH .. " characters"
    end

    if #password > consts.LIMITS.MAX_PASSWORD_LENGTH then
        return false, "Password exceeds maximum length"
    end

    return true
end

-- Facts of one login. The token's actor metadata keeps them under `session`,
-- which wippy/relay leaves out when it compares a user's authority; at the
-- top level they would make every login of the user a new authority.
consts.LOGIN_FACTS = { "login_time", "ip_address", "user_agent" }

-- The login facts of actor metadata, each read separately. Tokens issued
-- before the facts moved under `session` keep the server's values at the top
-- level, and a `session` table in such a token came from the client, so a
-- top-level value wins. Newer tokens have no top-level facts.
function consts.login_facts(metadata)
    local session = type(metadata.session) == "table" and metadata.session or {}
    local facts = {}
    for _, key in ipairs(consts.LOGIN_FACTS) do
        local value = metadata[key]
        if value == nil then
            value = session[key]
        end
        facts[key] = value
    end
    return facts
end

-- A copy of actor metadata for HTTP responses. It also carries the login
-- facts at the top level, where the responses had them before; the token's
-- actor metadata keeps them only under `session`.
function consts.response_metadata(metadata)
    local copy = {}
    for key, value in pairs(metadata) do
        copy[key] = value
    end
    for key, value in pairs(consts.login_facts(metadata)) do
        copy[key] = value
    end
    return copy
end

return consts