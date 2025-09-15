local ctx = require("ctx")
local json = require("json")
local sql = require("sql")

-- Constants
local DB_RESOURCE_ID = "app:db"
local CONTEXT_KEY = "component_id"

local ERROR_CODES = {
    NO_CONTEXT = "NO_CONTEXT",
    DB_ERROR = "DB_ERROR",
    KB_LOOKUP_FAILED = "KB_LOOKUP_FAILED",
    KB_NOT_FOUND = "KB_NOT_FOUND",
    BASIC_STATS_FAILED = "BASIC_STATS_FAILED",
    TYPE_STATS_FAILED = "TYPE_STATS_FAILED"
}

local TABLES = {
    KB_COMPONENTS = "kb_components",
    KB_NODES = "kb_nodes"
}

local COLUMNS = {
    ID = "id",
    COMPONENT_ID = "component_id",
    KB_ID = "kb_id",
    NODE_TYPE = "node_type",
    PATH = "path",
    CONTENT = "content",
    METADATA = "metadata",
    CREATED_AT = "created_at",
    UPDATED_AT = "updated_at"
}

local function handle(request_dto)
    local component_id, err = ctx.get(CONTEXT_KEY)
    if err then
        return {
            success = false,
            error = { code = ERROR_CODES.NO_CONTEXT, message = "No component context: " .. err }
        }
    end

    local req = request_dto or {}

    -- Extract parameters with defaults
    local include_content_size = req.include_content_size == true -- default false

    -- Get database connection
    local db, db_err = sql.get(DB_RESOURCE_ID)
    if db_err then
        return {
            success = false,
            error = { code = ERROR_CODES.DB_ERROR, message = "Failed to get database: " .. db_err }
        }
    end

    -- Get internal KB ID from component_id
    local kb_comp_sql = "SELECT " .. COLUMNS.ID .. " FROM " .. TABLES.KB_COMPONENTS .. " WHERE " .. COLUMNS.COMPONENT_ID .. " = ?"
    local kb_comp_result, kb_comp_err = db:query(kb_comp_sql, {component_id})

    if kb_comp_err then
        db:release()
        return {
            success = false,
            error = { code = ERROR_CODES.KB_LOOKUP_FAILED, message = "Failed to lookup KB: " .. kb_comp_err }
        }
    end

    if #kb_comp_result == 0 then
        db:release()
        return {
            success = false,
            error = { code = ERROR_CODES.KB_NOT_FOUND, message = "Knowledge base not found for component: " .. component_id }
        }
    end

    local kb_id = kb_comp_result[1].id

    -- 1. Get basic node stats
    local basic_sql
    if include_content_size then
        basic_sql = "SELECT COUNT(*) as total, COUNT(" .. COLUMNS.CONTENT .. ") as with_content, MIN(" .. COLUMNS.CREATED_AT .. ") as first_created, MAX(" .. COLUMNS.UPDATED_AT .. ") as last_updated, SUM(LENGTH(COALESCE(" .. COLUMNS.CONTENT .. ", ''))) as total_content_size, SUM(LENGTH(COALESCE(" .. COLUMNS.METADATA .. ", ''))) as total_metadata_size FROM " .. TABLES.KB_NODES .. " WHERE " .. COLUMNS.KB_ID .. " = ?"
    else
        basic_sql = "SELECT COUNT(*) as total, COUNT(" .. COLUMNS.CONTENT .. ") as with_content, MIN(" .. COLUMNS.CREATED_AT .. ") as first_created, MAX(" .. COLUMNS.UPDATED_AT .. ") as last_updated FROM " .. TABLES.KB_NODES .. " WHERE " .. COLUMNS.KB_ID .. " = ?"
    end

    local basic_result, basic_err = db:query(basic_sql, {kb_id})

    if basic_err then
        db:release()
        return {
            success = false,
            error = { code = ERROR_CODES.BASIC_STATS_FAILED, message = "Failed to get basic stats: " .. basic_err }
        }
    end

    local basic_stats = basic_result[1]

    -- 2. Get node type distribution
    local type_sql = "SELECT " .. COLUMNS.NODE_TYPE .. ", COUNT(*) as count FROM " .. TABLES.KB_NODES .. " WHERE " .. COLUMNS.KB_ID .. " = ? GROUP BY " .. COLUMNS.NODE_TYPE
    local type_result, type_err = db:query(type_sql, {kb_id})

    if type_err then
        db:release()
        return {
            success = false,
            error = { code = ERROR_CODES.TYPE_STATS_FAILED, message = "Failed to get type stats: " .. type_err }
        }
    end

    local node_types = {}
    for _, row in ipairs(type_result) do
        node_types[row.node_type] = row.count
    end

    -- Release database
    db:release()

    -- Build response
    local response = {
        success = true,
        nodes = {
            total = basic_stats.total,
            with_content = basic_stats.with_content
        },
        node_types = node_types,
        date_range = {
            first_created = basic_stats.first_created,
            last_updated = basic_stats.last_updated
        }
    }

    -- Add optional size fields
    if include_content_size then
        if basic_stats.total_content_size then
            response.nodes.total_content_size = basic_stats.total_content_size
        end
        if basic_stats.total_metadata_size then
            response.nodes.total_metadata_size = basic_stats.total_metadata_size
        end
    end

    return response
end

return { handle = handle }