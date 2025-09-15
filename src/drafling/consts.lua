local consts = {}

-- Database and host constants
consts.APP_DB = "app:db"

-- Content type constants
consts.CONTENT_TYPE = {
    TEXT_PLAIN = "text/plain",
    TEXT_MARKDOWN = "text/markdown",
    TEXT_HTML = "text/html",
    APPLICATION_JSON = "application/json",
    CODE_JAVASCRIPT = "text/javascript",
    CODE_PYTHON = "text/python",
    CODE_SQL = "text/sql",
    IMAGE_PNG = "image/png",
    IMAGE_JPEG = "image/jpeg"
}

-- Status constants
consts.STATUS = {
    DRAFT = "draft",
    ACTIVE = "active",
    PUBLISHED = "published",
    ARCHIVED = "archived",
    DELETED = "deleted",
    TEMPLATE = "template"
}

-- Operation type constants (CQRS commands)
consts.OPERATION_TYPE = {
    -- Document operations
    CREATE_PROJECT = "CREATE_PROJECT",
    UPDATE_PROJECT = "UPDATE_PROJECT",
    DELETE_PROJECT = "DELETE_PROJECT",

    -- Category operations
    CREATE_CATEGORY = "CREATE_CATEGORY",
    UPDATE_CATEGORY = "UPDATE_CATEGORY",
    DELETE_CATEGORY = "DELETE_CATEGORY",

    -- Entry operations
    CREATE_ENTRY = "CREATE_ENTRY",
    UPDATE_ENTRY = "UPDATE_ENTRY",
    DELETE_ENTRY = "DELETE_ENTRY"
}

-- Update operation field types
consts.UPDATE_FIELD_TYPE = {
    -- Document fields
    PROJECT_TITLE = "title",
    PROJECT_STATUS = "status",
    PROJECT_METADATA = "metadata",

    -- Category fields
    CATEGORY_DISPLAY_NAME = "display_name",
    CATEGORY_METADATA = "metadata",

    -- Entry fields
    ENTRY_TYPE = "type",
    ENTRY_CONTENT = "content",
    ENTRY_CONTENT_TYPE = "content_type",
    ENTRY_TITLE = "title",
    ENTRY_STATUS = "status",
    ENTRY_METADATA = "metadata"
}

-- History operation types
consts.HISTORY_OPERATION = {
    CREATE = "create",
    UPDATE = "update",
    DELETE = "delete"
}

-- History change structure constants
consts.HISTORY_CHANGE = {
    -- Change structure keys
    OPERATION = "operation",
    FIELDS_CHANGED = "fields_changed",
    FROM = "from",
    TO = "to",
    INITIAL_VALUES = "initial_values",
    DELETED_VALUES = "deleted_values",

    -- Operation values
    OP_CREATE = "create",
    OP_UPDATE = "update",
    OP_DELETE = "delete"
}

-- Trackable field sets for history
consts.TRACKABLE_FIELDS = {
    PROJECT = {
        "title",
        "status",
        "metadata"
    },
    CATEGORY = {
        "display_name",
        "metadata"
    },
    ENTRY = {
        "type",
        "content",
        "content_type",
        "title",
        "status",
        "metadata"
    }
}

-- Real-time topic patterns
consts.TOPIC = {
    USER_PROJECT_PREFIX = "user.",
    PROJECT_PREFIX = "project:",
    -- Full pattern: "project:{project_id}"
}

-- Error message constants
consts.ERROR = {
    -- General errors
    MISSING_REQUIRED_FIELD = "Missing required field: ",
    INVALID_FIELD_VALUE = "Invalid value for field: ",
    UNKNOWN_COMMAND_TYPE = "Unknown command type: ",

    -- Entity not found errors
    PROJECT_NOT_FOUND = "Document not found",
    CATEGORY_NOT_FOUND = "Category not found",
    ENTRY_NOT_FOUND = "Entry not found",

    -- Validation errors
    DUPLICATE_CATEGORY = "Category already exists in project",
    INVALID_PROJECT_TYPE = "Invalid project type",
    INVALID_ENTRY_TYPE = "Invalid entry type",
    INVALID_CONTENT_TYPE = "Invalid content type",
    INVALID_STATUS = "Invalid status value",

    -- Authorization errors
    UNAUTHORIZED_ACCESS = "Unauthorized access to project",
    CATEGORY_PROJECT_MISMATCH = "Category does not belong to the specified project",

    -- Operation errors
    NO_FIELDS_TO_UPDATE = "No fields provided for update",
    TRANSACTION_REQUIRED = "Transaction is required",
    COMMANDS_REQUIRED = "Commands must be provided",
    COMMANDS_EMPTY = "Commands array cannot be empty",

    -- Database errors
    DB_CONNECTION_FAILED = "Failed to connect to database",
    DB_OPERATION_FAILED = "Database operation failed",
    JSON_ENCODE_FAILED = "Failed to encode JSON",
    JSON_DECODE_FAILED = "Failed to decode JSON",
    HISTORY_CREATE_FAILED = "Failed to create history record"
}

-- Validation sets
consts.VALID_VALUES = {
    STATUS = {
        [consts.STATUS.DRAFT] = true,
        [consts.STATUS.ACTIVE] = true,
        [consts.STATUS.PUBLISHED] = true,
        [consts.STATUS.ARCHIVED] = true,
        [consts.STATUS.DELETED] = true,
        [consts.STATUS.TEMPLATE] = true
    },

    CONTENT_TYPE = {
        [consts.CONTENT_TYPE.TEXT_PLAIN] = true,
        [consts.CONTENT_TYPE.TEXT_MARKDOWN] = true,
        [consts.CONTENT_TYPE.TEXT_HTML] = true,
        [consts.CONTENT_TYPE.APPLICATION_JSON] = true,
        [consts.CONTENT_TYPE.CODE_JAVASCRIPT] = true,
        [consts.CONTENT_TYPE.CODE_PYTHON] = true,
        [consts.CONTENT_TYPE.CODE_SQL] = true,
        [consts.CONTENT_TYPE.IMAGE_PNG] = true,
        [consts.CONTENT_TYPE.IMAGE_JPEG] = true
    },

    HISTORY_OPERATION = {
        [consts.HISTORY_OPERATION.CREATE] = true,
        [consts.HISTORY_OPERATION.UPDATE] = true,
        [consts.HISTORY_OPERATION.DELETE] = true
    }
}

-- Default values
consts.DEFAULTS = {
    PROJECT_STATUS = consts.STATUS.DRAFT,
    ENTRY_CONTENT_TYPE = consts.CONTENT_TYPE.TEXT_PLAIN,
    ENTRY_STATUS = consts.STATUS.ACTIVE,
    METADATA = "{}"
}

return consts