local env = require("env")

local consts = {
    -- Environment Variable IDs
    ENV_IDS = {
        EXECUTOR_ID = "userspace.mcp.env:executor_id",
        PROTOCOL_VERSION = "userspace.mcp.env:protocol_version",
        CLIENT_NAME = "userspace.mcp.env:client_name",
        CLIENT_VERSION = "userspace.mcp.env:client_version"
    },

    -- MCP Operations
    OPERATIONS = {
        INITIALIZE = "initialize",
        INITIALIZED = "notifications/initialized",
        TOOLS_LIST = "tools/list",
        TOOLS_CALL = "tools/call"
    },

    -- Default Values
    DEFAULTS = {
        EXECUTOR_ID = "userspace.mcp:executor",
        PROTOCOL_VERSION = "2024-11-05",
        CLIENT_NAME = "wippy-mcp-client",
        CLIENT_VERSION = "1.0.0",
        REQUEST_ID_START = 1,
        INIT_DELAY_MS = 1000,
        RESPONSE_TIMEOUT_MS = 10000,
        SHUTDOWN_DELAY_MS = 2000,
        TOOLS_REQUEST_DELAY_MS = 500,
        REQUEST_TIMEOUT_MS = 30000,
        TOOL_CALL_TIMEOUT_MS = 300000
    },

    -- Registry
    REGISTRY = {
        PREFIX = "mcp."
    },

    -- Topics
    TOPICS = {
        REQUEST = "request",
        RESPONSE = "response"
    },

    -- Error Messages
    ERRORS = {
        MISSING_EXECUTABLE = "Missing executable path in arguments",
        MISSING_NAME = "Missing MCP server name in arguments",
        EXECUTOR_FAILED = "Failed to get executor",
        PROCESS_START_FAILED = "Failed to start MCP process",
        PROCESS_WRITE_FAILED = "Failed to write to MCP process",
        INIT_FAILED = "MCP initialization failed",
        TOOLS_LIST_FAILED = "Failed to get tools list",
        RESPONSE_TIMEOUT = "Response timeout",
        INVALID_RESPONSE = "Invalid JSON response",
        PROCESS_CLOSED = "MCP process is closed",
        REGISTRY_FAILED = "Failed to register process"
    },

    -- Stream Types
    STREAM_TYPES = {
        HTTP = "http",
        EXEC = "exec"
    }
}

function consts.get_executor_id()
    local executor_id, _ = env.get(consts.ENV_IDS.EXECUTOR_ID)
    return executor_id or consts.DEFAULTS.EXECUTOR_ID
end

function consts.get_protocol_version()
    local version, _ = env.get(consts.ENV_IDS.PROTOCOL_VERSION)
    return version or consts.DEFAULTS.PROTOCOL_VERSION
end

function consts.get_client_info()
    local name, _ = env.get(consts.ENV_IDS.CLIENT_NAME)
    local version, _ = env.get(consts.ENV_IDS.CLIENT_VERSION)

    return {
        name = name or consts.DEFAULTS.CLIENT_NAME,
        version = version or consts.DEFAULTS.CLIENT_VERSION
    }
end

function consts.get_config()
    return {
        executor_id = consts.get_executor_id(),
        protocol_version = consts.get_protocol_version(),
        client_info = consts.get_client_info()
    }
end

return table.freeze(consts)