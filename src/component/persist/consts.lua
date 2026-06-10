-- component-owned constants. Single source for the db resource id, the three
-- backing table names, the access bitmask vocabulary, the command-type strings,
-- list defaults, and the lexorank alphabet. Nothing in the persist or binding
-- layer hardcodes these. Errors are structured via the global errors module.

local M = {}

-- Connection resource id the consuming app binds the component db to.
M.DB_RESOURCE = "app:db"

-- Backing tables (created by the module's migrations).
M.TABLES = {
    -- Component registry rows (one per component, incl. placement columns).
    COMPONENTS = "components",
    -- Public key-value metadata per component.
    META = "component_meta",
    -- Bitmask access grants; user_id column holds a user OR a group id.
    ACCESS = "component_access",
}

-- Access mask bits (bitmask permissions) and the common combinations.
M.ACCESS = {
    NONE = 0,   -- 0000 - No access
    READ = 1,   -- 0001 - Read component metadata
    WRITE = 2,  -- 0010 - Modify component metadata
    DELETE = 4, -- 0100 - Delete component
    ADMIN = 8,  -- 1000 - Grant/revoke permissions

    READ_WRITE = 3,   -- 0011 - Read and write
    READ_DELETE = 5,  -- 0101 - Read and delete
    WRITE_DELETE = 6, -- 0110 - Write and delete
    FULL = 15,        -- 1111 - All permissions
}

-- Command-type discriminators for ops.handlers.
M.COMMAND_TYPES = {
    CREATE_COMPONENT = "CREATE_COMPONENT",
    DELETE_COMPONENT = "DELETE_COMPONENT",
    PUT_META = "PUT_META",
    DELETE_META = "DELETE_META",
    GRANT_ACCESS = "GRANT_ACCESS",
    REVOKE_ACCESS = "REVOKE_ACCESS",
    SET_PLACEMENT = "SET_PLACEMENT",
}

-- Listing/ordering defaults shared by reader and binding funcs.
M.DEFAULTS = {
    ACCESS_MASK = 15, -- FULL access granted to a component's creator
    ORDER_BY = "created_at",
    ORDER_DIRECTION = "DESC",
    LIMIT = 50,
}

-- Pagination bounds enforced by listing endpoints.
M.PAGINATION = {
    MIN_LIMIT = 1,
    MAX_LIMIT = 100,
    DEFAULT_LIMIT = 50,
    MIN_OFFSET = 0,
    DEFAULT_OFFSET = 0,
}

-- lexorank alphabet: digits then lowercase letters, ordered by byte value, so a
-- midpoint string sorts strictly between any two neighbors.
M.LEXORANK = {
    ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz",
}

-- Path separator for the sqlite materialized-path representation. Presence of
-- this separator in a stored path also discriminates sqlite paths from pg ltree
-- labels (which use ".").
M.PATH_SEPARATOR = "/"

return M
