local sql = require("sql")
local json = require("json")
local consts = require("drafling_consts")

local history_repo = {}

-- ============================================================================
-- PRIVATE HELPERS
-- ============================================================================

-- Get database connection
local function get_db()
    local db, err = sql.get(consts.APP_DB)
    if err then
        return nil, "Failed to connect to database: " .. err
    end
    return db
end

-- Parse JSON changes field
local function parse_history_record(history_row)
    if not history_row then
        return nil
    end

    -- Parse changes JSON
    if history_row.changes and type(history_row.changes) == "string" then
        local decoded, err = json.decode(history_row.changes)
        if not err then
            history_row.changes = decoded
        else
            history_row.changes = {}
        end
    elseif history_row.changes == nil then
        history_row.changes = {}
    end

    return history_row
end

-- Helper to create a parameterized IN clause
local function create_in_clause(field, values)
    if not values or #values == 0 then
        return nil
    end

    if #values == 1 then
        return { field .. " = ?", values[1] }
    end

    local placeholders = {}
    for i = 1, #values do
        table.insert(placeholders, "?")
    end

    return { field .. " IN (" .. table.concat(placeholders, ", ") .. ")", unpack(values) }
end

-- ============================================================================
-- HISTORY QUERIES
-- ============================================================================

-- Get history for a specific entry
function history_repo.get_entry_history(entry_id, options)
    if not entry_id or entry_id == "" then
        return nil, "Entry ID is required"
    end

    options = options or {}

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local query = sql.builder.select("*")
        :from("drafling_entry_history")
        :where("entry_id = ?", entry_id)

    -- Filter by operation type
    if options.operation_type then
        query = query:where("operation_type = ?", options.operation_type)
    end

    -- Ordering (default: newest first)
    if options.order == "oldest" then
        query = query:order_by("created_at ASC")
    else
        query = query:order_by("created_at DESC")
    end

    -- Pagination
    if options.limit and tonumber(options.limit) > 0 then
        query = query:limit(tonumber(options.limit))
    end

    if options.offset and tonumber(options.offset) >= 0 then
        query = query:offset(tonumber(options.offset))
    end

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to get entry history: " .. err
    end

    -- Parse changes in all results
    local history = {}
    for _, row in ipairs(results or {}) do
        table.insert(history, parse_history_record(row))
    end

    return history
end

-- Get history for all entries in a project
function history_repo.get_project_history(project_id, options)
    if not project_id or project_id == "" then
        return nil, "Document ID is required"
    end

    options = options or {}

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local query = sql.builder.select("*")
        :from("drafling_entry_history")
        :where("project_id = ?", project_id)

    -- Filter by operation type
    if options.operation_type then
        query = query:where("operation_type = ?", options.operation_type)
    end

    -- Filter by specific entries
    if options.entry_ids and #options.entry_ids > 0 then
        local entry_clause = create_in_clause("entry_id", options.entry_ids)
        if entry_clause then
            query = query:where(sql.builder.expr(unpack(entry_clause)))
        end
    end

    -- Ordering (default: newest first)
    if options.order == "oldest" then
        query = query:order_by("created_at ASC")
    else
        query = query:order_by("created_at DESC")
    end

    -- Pagination
    if options.limit and tonumber(options.limit) > 0 then
        query = query:limit(tonumber(options.limit))
    end

    if options.offset and tonumber(options.offset) >= 0 then
        query = query:offset(tonumber(options.offset))
    end

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to get project history: " .. err
    end

    -- Parse changes in all results
    local history = {}
    for _, row in ipairs(results or {}) do
        table.insert(history, parse_history_record(row))
    end

    return history
end

-- Get history statistics for a user
function history_repo.get_user_history_stats(user_id, options)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    options = options or {}

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    -- Get counts by operation type
    local ops_query = sql.builder.select("h.operation_type", "COUNT(*) as count")
        :from("drafling_entry_history h")
        :join("drafling_projects d ON h.project_id = d.project_id")
        :where("d.user_id = ?", user_id)

    -- Add time filter if specified
    if options.since then
        ops_query = ops_query:where("h.created_at >= ?", options.since)
    end

    ops_query = ops_query:group_by("h.operation_type")
        :order_by("h.operation_type")

    local ops_executor = ops_query:run_with(db)
    local ops_results, ops_err = ops_executor:query()

    if ops_err then
        db:release()
        return nil, "Failed to get operation stats: " .. ops_err
    end

    -- Get activity by day
    local activity_query = sql.builder.select("DATE(h.created_at) as date", "COUNT(*) as count")
        :from("drafling_entry_history h")
        :join("drafling_projects d ON h.project_id = d.project_id")
        :where("d.user_id = ?", user_id)

    -- Add time filter if specified
    if options.since then
        activity_query = activity_query:where("h.created_at >= ?", options.since)
    end

    activity_query = activity_query:group_by("DATE(h.created_at)")
        :order_by("DATE(h.created_at) DESC")

    local activity_executor = activity_query:run_with(db)
    local activity_results, activity_err = activity_executor:query()

    db:release()

    if activity_err then
        return nil, "Failed to get activity stats: " .. activity_err
    end

    return {
        operations_by_type = ops_results or {},
        activity_by_date = activity_results or {}
    }
end

-- Get the latest history record for an entry
function history_repo.get_entry_latest_history(entry_id)
    if not entry_id or entry_id == "" then
        return nil, "Entry ID is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local query = sql.builder.select("*")
        :from("drafling_entry_history")
        :where("entry_id = ?", entry_id)
        :order_by("created_at DESC")
        :limit(1)

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to get latest history: " .. err
    end

    if not results or #results == 0 then
        return nil, nil -- No history found
    end

    return parse_history_record(results[1])
end

-- Check if an entry has any history
function history_repo.entry_has_history(entry_id)
    if not entry_id or entry_id == "" then
        return false, "Entry ID is required"
    end

    local db, err_db = get_db()
    if err_db then
        return false, err_db
    end

    local query = sql.builder.select("COUNT(*) as count")
        :from("drafling_entry_history")
        :where("entry_id = ?", entry_id)

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return false, "Failed to check history existence: " .. err
    end

    return results[1].count > 0, nil
end

return history_repo