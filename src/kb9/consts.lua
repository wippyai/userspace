local consts = {}

-- Process registry names
consts.PROCESS_NAMES = {
    ROOT_SERVICE = "kb9.service.root",
    KB_PROCESS_PREFIX = "kb9.kb." -- Individual KB processes: "kb9.kb.{component_id}"
}

-- Process spawn configuration
consts.PROCESS_SPAWN = {
    KB_PROCESS_ID = "userspace.kb9.service:kb_process",
    KB_HOST_ID = "app:processes"
}

-- Command type constants - minimal set covering all operations
consts.COMMAND_TYPES = {
    -- Component Operations
    CREATE_COMPONENT = "CREATE_COMPONENT",
    UPDATE_COMPONENT = "UPDATE_COMPONENT",
    DELETE_COMPONENT = "DELETE_COMPONENT",

    -- Node Operations
    CREATE_NODE = "CREATE_NODE",
    UPDATE_NODE = "UPDATE_NODE",
    DELETE_NODE = "DELETE_NODE",
    MOVE_NODE = "MOVE_NODE", -- Keep for future implementation

    -- Embedding Operations
    UPSERT_EMBEDDING = "UPSERT_EMBEDDING", -- Insert or update embedding for node
    DELETE_EMBEDDING = "DELETE_EMBEDDING", -- Delete embedding for node

    -- Multiple delete operations
    DELETE_NODES = "DELETE_NODES",

    -- KB Process Commands (sent to root service, forwarded to KB processes)
    INIT_EMBED = "INIT_EMBED",           -- Initialize/update embed contract
    INIT_QUERY = "INIT_QUERY",           -- Initialize/update query contract
    EMBED_CONTENT = "EMBED_CONTENT",     -- Embed direct content
    EMBED_REFERENCE = "EMBED_REFERENCE", -- Embed from content provider reference
    DELETE_KB = "DELETE_KB",             -- Delete entire KB and shutdown process
    RUN_ROUTINE = "RUN_ROUTINE"          -- Run custom routine (future)
}

-- Message topics - simplified to single command path
consts.MESSAGE_TOPICS = {
    KB_COMMAND = "kb_command",       -- Commands sent to root service (always as array)
    KB_READY = "kb_ready",           -- KB process ready signal
    COMMAND = "command",             -- Commands to KB process (always as array)
    KB_ASK = "kb_ask",               -- Acknowledgment responses from KB processes
    IDLE_CHECK = "idle_check"        -- Idle timeout check from root
}

-- Command message formats for KB operations
-- All commands sent to root as: process.send(root_pid, MESSAGE_TOPICS.KB_COMMAND, command_msg)
-- Command message format: { component_id = "...", commands = [{ type = "...", payload = {...} }], reply_to = "..." }
--
-- Acknowledgment message format: { success = true/false, error = "...", command_type = "...", ops_executed = 0, ... }
-- Startup error format: { startup_error = true, error = "...", component_id = "..." }
consts.KB_COMMAND_FORMATS = {
    -- INIT_EMBED: Update embed contract configuration
    -- payload: { embed_contract = { binding_id = "...", options = {...} } }

    -- INIT_QUERY: Update query contract configuration
    -- payload: { query_contract = { binding_id = "...", options = {...} } }

    -- EMBED_CONTENT: Embed direct text content
    -- payload: { content = "...", content_type = "text/plain", metadata = {...} }

    -- EMBED_REFERENCE: Embed content from external reference
    -- payload: { reference = { binding_id = "...", context = {...} }, metadata = {...} }

    -- DELETE_KB: Delete entire knowledge base and shutdown process
    -- payload: {} (no additional data needed)

    -- RUN_ROUTINE: Execute custom routine (future use)
    -- payload: { routine_id = "...", params = {...} }
}

-- KB Process configuration (controlled by root service)
consts.KB_PROCESS = {
    IDLE_TIMEOUT = "30s",          -- How long KB process stays alive without activity (checked by root)
    STARTUP_TIMEOUT = "10s",       -- Max time to wait for KB process startup
    RESTART_DELAY = "1s",          -- Delay between restart attempts
    CANCEL_TIMEOUT = "1s",         -- Timeout for graceful cancellation
    TIMEOUT_CHECK_INTERVAL = "5s", -- How often root service checks for timeouts
    DELETE_TIMEOUT = "30s"         -- How long to wait for KB deletion to complete
}

-- Response timeouts
consts.ASK_TIMEOUT = "50s" -- How long to wait for acknowledgment responses
consts.EMBED_TIMEOUT = "600s" -- How long to wait for acknowledgment responses
consts.DELETE_TIMEOUT = "60s" -- How long to wait for deletion acknowledgment

-- Component registration configuration
consts.COMPONENT = {
    IMPL_ID = "userspace.kb9.binding:kb9_component",
    DEFAULT_DESCRIPTION = "KB9 configurable knowledge base",
    CLASS = "knowledge_base",
    TYPE = "KB9 Knowledge Base"
}

-- Path configuration
consts.PATH = {
    SEPARATOR = ".",
    SEGMENT_WIDTH = 8, -- 00000001, 00000002, etc.
    INCREMENT = 100    -- Leave gaps for future insertions (00100, 00200, 00300...)
}

-- Operation status constants
consts.OPERATION_STATUS = {
    PROCESSING = "processing",
    COMPLETED = "completed",
    FAILED = "failed"
}

-- Content type constants
consts.CONTENT_TYPES = {
    TEXT = "text/plain",
    MARKDOWN = "text/markdown",
    HTML = "text/html",
    JSON = "application/json"
}

-- Vector dimensions
consts.VECTOR_DIMENSIONS = 512

-- Error messages
consts.ERROR = {
    INVALID_KB_ID = "KB ID is required",
    INVALID_COMPONENT_ID = "Component ID is required",
    INVALID_NODE_ID = "Node ID is required",
    INVALID_CONTENT_TYPE = "Invalid content type",
    INVALID_EMBEDDING_DIM = "Embedding dimension must be " .. consts.VECTOR_DIMENSIONS,
    CIRCULAR_REFERENCE = "Circular reference detected",
    NODE_NOT_FOUND = "Node not found",
    COMPONENT_NOT_FOUND = "Component not found",
    PARENT_NOT_FOUND = "Parent node not found",
    INVALID_PATH = "Invalid path format",
    INVALID_EMBEDDING = "Invalid embedding vector",
    EMBEDDING_NOT_FOUND = "Embedding not found"
}

return consts