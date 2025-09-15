local sql = require("sql")
local json = require("json")
local time = require("time")
local uuid = require("uuid")

-- Constants
local APP_DB = "app:db"

-- Status constants
local STATUS = {
    SCHEDULED = "scheduled",
    EXECUTING = "executing",
    COMPLETED = "completed",
    FAILED = "failed",
    DISABLED = "disabled"
}

-- Schedule type constants
local SCHEDULE_TYPES = {
    ONCE = "once",
    INTERVAL = "interval",
    TICKER = "ticker",
    CRON = "cron"
}

-- Cache database type for performance
local cached_db_type = nil

---@class ScheduleData
---@field id string
---@field description string|nil
---@field class string
---@field user_id string|nil
---@field task_implementation_id string
---@field task_context table
---@field task_args table
---@field schedule_type string
---@field schedule_expression string
---@field next_run_at string|nil
---@field last_run_at string|nil
---@field status string
---@field enabled boolean
---@field picked boolean
---@field picked_by string|nil
---@field picked_at string|nil
---@field timeout_seconds integer
---@field retry_count integer
---@field max_retries integer
---@field consecutive_failures integer
---@field last_error string|nil
---@field actor_id string|nil
---@field actor_scope string|nil
---@field actor_metadata table
---@field created_at string
---@field updated_at string

---@class ScheduleCreateData
---@field description string|nil
---@field class string|nil
---@field user_id string|nil
---@field task_implementation_id string
---@field task_context table|nil
---@field task_args table|nil
---@field schedule_type string
---@field schedule_expression string
---@field next_run_at string|nil
---@field timeout_seconds integer|nil
---@field max_retries integer|nil
---@field enabled boolean|nil
---@field actor_id string|nil
---@field actor_scope string|nil
---@field actor_metadata table|nil

---@class ScheduleUpdates
---@field description string|nil
---@field schedule_expression string|nil
---@field task_context table|nil
---@field task_args table|nil
---@field timeout_seconds integer|nil
---@field max_retries integer|nil
---@field enabled boolean|nil
---@field next_run_at string|nil
---@field status string|nil
---@field actor_id string|nil
---@field actor_scope string|nil
---@field actor_metadata table|nil

---@class ScheduleExecutionResult
---@field duration_ms integer|nil
---@field error string|nil

---@class ScheduleFilters
---@field status string|nil
---@field enabled boolean|nil
---@field class string|nil
---@field task_implementation_id string|nil
---@field schedule_type string|nil
---@field user_id string|nil
---@field actor_id string|nil
---@field actor_scope string|nil

---@class Pagination
---@field limit integer|nil
---@field offset integer|nil

---@class Ordering
---@field field string|nil
---@field direction string|nil

-- Create the module table
local schedule_repo = {}

---Helper to get database connection
---@return table, string|nil -- db, error
local function get_db()
    local db, err = sql.get(APP_DB)
    if err then
        return nil, "Failed to connect to database: " .. err
    end
    return db, nil
end

---Helper to get and cache database type
---@return string
local function get_database_type()
    if cached_db_type then
        return cached_db_type
    end

    local db, err = get_db()
    if err then
        return "unknown"
    end

    local db_type, type_err = db:type()
    db:release()

    if not type_err and db_type then
        cached_db_type = db_type
        return db_type
    end

    return "unknown"
end

---Helper to encode time for database storage - ALWAYS STORES UTC
---@param time_obj userdata|string|nil
---@return string|integer|nil
local function encode_time_for_db(time_obj)
    if not time_obj then
        return nil
    end

    -- ENSURE UTC before any storage operations
    local utc_time
    if type(time_obj) == "string" then
        -- Parse and convert to UTC
        local parsed_time, parse_err = time.parse(time.RFC3339, time_obj)
        if parse_err then
            return nil
        end
        utc_time = parsed_time:utc() -- Convert to UTC
    elseif time_obj.utc then
        -- Time object (userdata with methods) - convert to UTC
        utc_time = time_obj:utc() -- Convert to UTC
    else
        return nil
    end

    -- Store UTC time in appropriate format for database
    local db_type = get_database_type()
    if db_type == sql.type.SQLITE then
        return utc_time:unix()               -- Unix timestamps are inherently UTC
    else
        return utc_time:format(time.RFC3339) -- Store as UTC string
    end
end

---Helper to decode time from database - ALWAYS RETURNS UTC
---@param db_time string|integer|nil
---@return string|nil
local function decode_time_from_db(db_time)
    if not db_time then
        return nil
    end

    local db_type = get_database_type()

    if db_type == sql.type.SQLITE and type(db_time) == "number" then
        -- Unix timestamps are UTC by definition
        local time_obj = time.unix(db_time, 0)
        return time_obj:utc():format(time.RFC3339)
    elseif type(db_time) == "string" then
        -- Parse and ensure UTC
        local parsed_time, parse_err = time.parse(time.RFC3339, db_time)
        if parse_err then
            return db_time -- Return as-is if parsing fails
        end
        return parsed_time:utc():format(time.RFC3339)
    end

    return db_time
end

---Helper to encode JSON data
---@param data table
---@return string
local function encode_json(data)
    if not data or type(data) ~= "table" then
        return "{}"
    end

    local encoded, err = json.encode(data)
    if err then
        return "{}"
    else
        return encoded
    end
end

---Helper to decode JSON data
---@param json_str string|nil
---@return table
local function decode_json(json_str)
    if not json_str or type(json_str) ~= "string" then
        return {}
    end

    local decoded, err = json.decode(json_str)
    if err or type(decoded) ~= "table" then
        return {}
    else
        return decoded
    end
end

---Helper to convert database row to ScheduleData
---@param row table
---@return ScheduleData
local function row_to_schedule_data(row)
    return {
        id = row.id,
        description = row.description,
        class = row.class,
        user_id = row.user_id,
        task_implementation_id = row.task_implementation_id,
        task_context = decode_json(row.task_context),
        task_args = decode_json(row.task_args),
        schedule_type = row.schedule_type,
        schedule_expression = row.schedule_expression,
        next_run_at = decode_time_from_db(row.next_run_at),
        last_run_at = decode_time_from_db(row.last_run_at),
        status = row.status,
        enabled = row.enabled,
        picked = row.picked,
        picked_by = row.picked_by,
        picked_at = decode_time_from_db(row.picked_at),
        timeout_seconds = row.timeout_seconds or 3600,
        retry_count = row.retry_count or 0,
        max_retries = row.max_retries or 3,
        consecutive_failures = row.consecutive_failures or 0,
        last_error = row.last_error,
        actor_id = row.actor_id,
        actor_scope = row.actor_scope,
        actor_metadata = decode_json(row.actor_metadata),
        created_at = decode_time_from_db(row.created_at),
        updated_at = decode_time_from_db(row.updated_at)
    }
end

-- =============================================================================
-- CRUD OPERATIONS
-- =============================================================================

---Create a new scheduled task
---@param task_data ScheduleCreateData
---@return string|nil, string|nil -- task_id, error
function schedule_repo.create(task_data)
    if not task_data or type(task_data) ~= "table" then
        return nil, "Invalid task data"
    end

    -- Validate required fields
    if not task_data.task_implementation_id or task_data.task_implementation_id == "" then
        return nil, "task_implementation_id is required"
    end

    if not task_data.schedule_type or task_data.schedule_type == "" then
        return nil, "schedule_type is required"
    end

    if not task_data.schedule_expression or task_data.schedule_expression == "" then
        return nil, "schedule_expression is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local tx, tx_err = db:begin()
    if tx_err then
        db:release()
        return nil, "Failed to begin transaction: " .. tx_err
    end

    -- Generate task ID and prepare data
    local task_id = uuid.v7()
    local now_time = time.now():utc() -- Always use UTC

    local insert_data = {
        id = task_id,
        description = task_data.description,
        class = task_data.class or "user",
        user_id = task_data.user_id,
        task_implementation_id = task_data.task_implementation_id,
        task_context = encode_json(task_data.task_context or {}),
        task_args = encode_json(task_data.task_args or {}),
        schedule_type = task_data.schedule_type,
        schedule_expression = task_data.schedule_expression,
        next_run_at = encode_time_for_db(task_data.next_run_at),
        timeout_seconds = task_data.timeout_seconds or 3600,
        status = STATUS.SCHEDULED,
        enabled = task_data.enabled ~= false, -- Default to true
        picked = false,
        retry_count = 0,
        max_retries = task_data.max_retries or 3,
        consecutive_failures = 0,
        actor_id = task_data.actor_id,
        actor_scope = task_data.actor_scope,
        actor_metadata = encode_json(task_data.actor_metadata or {}),
        created_at = encode_time_for_db(now_time),
        updated_at = encode_time_for_db(now_time)
    }

    -- Insert the schedule
    local insert_query = sql.builder.insert("schedules"):set_map(insert_data)
    local executor = insert_query:run_with(tx)
    local result, insert_err = executor:exec()

    if insert_err then
        tx:rollback()
        db:release()
        return nil, "Failed to create schedule: " .. insert_err
    end

    -- Commit transaction
    local commit_ok, commit_err = tx:commit()
    if commit_err then
        tx:rollback()
        db:release()
        return nil, "Failed to commit transaction: " .. commit_err
    end

    db:release()
    return task_id, nil
end

---Get a schedule by ID
---@param task_id string
---@return ScheduleData|nil, string|nil -- schedule, error
function schedule_repo.get(task_id)
    if not task_id or task_id == "" then
        return nil, "task_id is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("*"):from("schedules"):where("id = ?", task_id)
    local executor = query:run_with(db)
    local results, query_err = executor:query()
    db:release()

    if query_err then
        return nil, "Failed to get schedule: " .. query_err
    end

    if not results or #results == 0 then
        return nil, "Schedule not found"
    end

    return row_to_schedule_data(results[1]), nil
end

---Update an existing schedule
---@param task_id string
---@param updates ScheduleUpdates
---@return boolean, string|nil -- success, error
function schedule_repo.update(task_id, updates)
    if not task_id or task_id == "" then
        return false, "task_id is required"
    end

    if not updates or type(updates) ~= "table" then
        return false, "updates table is required"
    end

    local db, err = get_db()
    if err then
        return false, err
    end

    local tx, tx_err = db:begin()
    if tx_err then
        db:release()
        return false, "Failed to begin transaction: " .. tx_err
    end

    -- Check if schedule exists
    local exists_query = sql.builder.select("id"):from("schedules"):where("id = ?", task_id)
    local exists_executor = exists_query:run_with(tx)
    local exists_result, exists_err = exists_executor:query()

    if exists_err then
        tx:rollback()
        db:release()
        return false, "Failed to check schedule existence: " .. exists_err
    end

    if not exists_result or #exists_result == 0 then
        tx:rollback()
        db:release()
        return false, "Schedule not found"
    end

    -- Build update query
    local update_query = sql.builder.update("schedules"):where("id = ?", task_id)

    -- Always update the updated_at timestamp
    update_query = update_query:set("updated_at", encode_time_for_db(time.now():utc()))

    -- Apply updates
    local has_updates = false
    for field, value in pairs(updates) do
        if field == "task_context" and type(value) == "table" then
            update_query = update_query:set(field, encode_json(value))
            has_updates = true
        elseif field == "task_args" and type(value) == "table" then
            update_query = update_query:set(field, encode_json(value))
            has_updates = true
        elseif field == "actor_metadata" and type(value) == "table" then
            update_query = update_query:set(field, encode_json(value))
            has_updates = true
        elseif field == "next_run_at" then
            update_query = update_query:set(field, encode_time_for_db(value))
            has_updates = true
        elseif field == "actor_id" then
            update_query = update_query:set(field, value)
            has_updates = true
        elseif field == "actor_scope" then
            update_query = update_query:set(field, value)
            has_updates = true
        elseif field ~= "id" then -- Don't allow ID updates
            update_query = update_query:set(field, value)
            has_updates = true
        end
    end

    if not has_updates then
        tx:rollback()
        db:release()
        return true, nil -- No updates to apply
    end

    -- Execute update
    local executor = update_query:run_with(tx)
    local result, update_err = executor:exec()

    if update_err then
        tx:rollback()
        db:release()
        return false, "Failed to update schedule: " .. update_err
    end

    -- Commit transaction
    local commit_ok, commit_err = tx:commit()
    if commit_err then
        tx:rollback()
        db:release()
        return false, "Failed to commit transaction: " .. commit_err
    end

    db:release()
    return true, nil
end

---Delete a schedule
---@param task_id string
---@return boolean, string|nil -- success, error
function schedule_repo.delete(task_id)
    if not task_id or task_id == "" then
        return false, "task_id is required"
    end

    local db, err = get_db()
    if err then
        return false, err
    end

    local delete_query = sql.builder.delete("schedules"):where("id = ?", task_id)
    local executor = delete_query:run_with(db)
    local result, delete_err = executor:exec()
    db:release()

    if delete_err then
        return false, "Failed to delete schedule: " .. delete_err
    end

    return result.rows_affected > 0, nil
end

---List schedules matching filters with pagination and ordering
---@param filters ScheduleFilters|nil
---@param options table|nil Pagination and ordering options
---@return ScheduleData[], string|nil -- schedules, error
function schedule_repo.list(filters, options)
    filters = filters or {}
    options = options or {}

    local db, err = get_db()
    if err then
        return {}, err
    end

    local query = sql.builder.select("*"):from("schedules")

    -- Apply filters
    if filters.status then
        query = query:where("status = ?", filters.status)
    end
    if filters.enabled ~= nil then
        query = query:where("enabled = ?", filters.enabled)
    end
    if filters.class then
        query = query:where("class = ?", filters.class)
    end
    if filters.task_implementation_id then
        query = query:where("task_implementation_id = ?", filters.task_implementation_id)
    end
    if filters.schedule_type then
        query = query:where("schedule_type = ?", filters.schedule_type)
    end
    if filters.user_id then
        query = query:where("user_id = ?", filters.user_id)
    end
    if filters.actor_id then
        query = query:where("actor_id = ?", filters.actor_id)
    end
    if filters.actor_scope then
        query = query:where("actor_scope = ?", filters.actor_scope)
    end

    -- Apply ordering
    local order_field = options.order_by or "created_at"
    local order_direction = options.order_direction or "DESC"
    query = query:order_by(order_field .. " " .. order_direction)

    -- Apply pagination
    if options.limit and options.limit > 0 then
        query = query:limit(options.limit)
    end

    if options.offset and options.offset > 0 then
        query = query:offset(options.offset)
    end

    local executor = query:run_with(db)
    local results, query_err = executor:query()
    db:release()

    if query_err then
        return {}, "Failed to list schedules: " .. query_err
    end

    -- Convert database rows to ScheduleData objects
    local schedules = {}
    for i, row in ipairs(results or {}) do
        schedules[i] = row_to_schedule_data(row)
    end

    return schedules, nil
end

-- =============================================================================
-- WORKER OPERATIONS
-- =============================================================================

---Claim ready tasks for execution using optimal database-specific methods
---@param worker_id string
---@param limit integer
---@return ScheduleData[], string|nil -- claimed_tasks, error
function schedule_repo.claim_ready_tasks(worker_id, limit)
    if not worker_id or worker_id == "" then
        return {}, "worker_id is required"
    end

    if not limit or limit <= 0 then
        limit = 5
    end

    local db_type = get_database_type()

    if db_type == sql.type.POSTGRES then
        return claim_ready_tasks_postgres(worker_id, limit)
    else
        return claim_ready_tasks_sqlite(worker_id, limit)
    end
end

---PostgreSQL implementation using FOR UPDATE SKIP LOCKED
---@param worker_id string
---@param limit integer
---@return ScheduleData[], string|nil -- claimed_tasks, error
function claim_ready_tasks_postgres(worker_id, limit)
    local db, err = get_db()
    if err then
        return {}, err
    end

    local tx, tx_err = db:begin()
    if tx_err then
        db:release()
        return {}, "Failed to begin transaction: " .. tx_err
    end

    local now_time = encode_time_for_db(time.now():utc()) -- Always use UTC

    -- Use FOR UPDATE SKIP LOCKED for efficient locking
    local select_sql = [[
        SELECT * FROM schedules
        WHERE enabled = true
          AND picked = false
          AND status = 'scheduled'
          AND (next_run_at IS NULL OR next_run_at <= ?)
        ORDER BY next_run_at ASC NULLS FIRST
        LIMIT ?
        FOR UPDATE SKIP LOCKED
    ]]

    local results, select_err = tx:query(select_sql, { now_time, limit })
    if select_err then
        tx:rollback()
        db:release()
        return {}, "Failed to select tasks: " .. select_err
    end

    if not results or #results == 0 then
        tx:rollback()
        db:release()
        return {}, nil -- No tasks ready
    end

    -- Mark selected tasks as picked
    local task_ids = {}
    for _, row in ipairs(results) do
        table.insert(task_ids, row.id)
    end

    local update_query = sql.builder.update("schedules")
        :set("picked", true)
        :set("picked_by", worker_id)
        :set("picked_at", now_time)

    -- Create IN clause for task IDs
    local placeholders = {}
    for i = 1, #task_ids do
        table.insert(placeholders, "?")
    end

    update_query = update_query:where(sql.builder.expr(
        "id IN (" .. table.concat(placeholders, ", ") .. ")",
        unpack(task_ids)
    ))

    local update_executor = update_query:run_with(tx)
    local update_result, update_err = update_executor:exec()

    if update_err then
        tx:rollback()
        db:release()
        return {}, "Failed to mark tasks as picked: " .. update_err
    end

    -- Commit transaction
    local commit_ok, commit_err = tx:commit()
    if commit_err then
        tx:rollback()
        db:release()
        return {}, "Failed to commit transaction: " .. commit_err
    end

    db:release()

    -- Convert results
    local schedules = {}
    for i, row in ipairs(results) do
        schedules[i] = row_to_schedule_data(row)
        -- Update the picked status since we just set it
        schedules[i].picked = true
        schedules[i].picked_by = worker_id
        schedules[i].picked_at = decode_time_from_db(now_time)
    end

    return schedules, nil
end

---SQLite implementation using atomic UPDATE...RETURNING (optimal for SQLite 3.35.0+)
---@param worker_id string
---@param limit integer
---@return ScheduleData[], string|nil -- claimed_tasks, error
function claim_ready_tasks_sqlite(worker_id, limit)
    local db, err = get_db()
    if err then
        return {}, err
    end

    local now_time = encode_time_for_db(time.now():utc()) -- Always use UTC

    -- Single atomic operation using UPDATE...RETURNING - no race conditions possible
    local atomic_claim_sql = [[
        UPDATE schedules
        SET picked = true, picked_by = ?, picked_at = ?
        WHERE id IN (
            SELECT id FROM schedules
            WHERE enabled = true
              AND picked = false
              AND status = 'scheduled'
              AND (next_run_at IS NULL OR next_run_at <= ?)
            ORDER BY next_run_at ASC NULLS FIRST
            LIMIT ?
        )
        RETURNING *
    ]]

    local results, update_err = db:query(atomic_claim_sql, {
        worker_id, now_time, now_time, limit
    })

    db:release()

    if update_err then
        return {}, "Failed to claim tasks atomically: " .. update_err
    end

    local schedules = {}
    for i, row in ipairs(results or {}) do
        schedules[i] = row_to_schedule_data(row)
    end

    return schedules, nil
end

---Mark a task as executing
---@param task_id string
---@return boolean, string|nil -- success, error
function schedule_repo.mark_executing(task_id)
    if not task_id or task_id == "" then
        return false, "task_id is required"
    end

    local db, err = get_db()
    if err then
        return false, err
    end

    local update_query = sql.builder.update("schedules")
        :set("status", STATUS.EXECUTING)
        :set("updated_at", encode_time_for_db(time.now():utc()))
        :where("id = ?", task_id)

    local executor = update_query:run_with(db)
    local result, update_err = executor:exec()
    db:release()

    if update_err then
        return false, "Failed to mark task as executing: " .. update_err
    end

    return result.rows_affected > 0, nil
end

---Reschedule a task for its next run using schedule calculator
---@param task_id string
---@param schedule_calculator table The schedule calculator module
---@return boolean, string|nil -- success, error
function schedule_repo.reschedule_task(task_id, schedule_calculator)
    if not task_id or task_id == "" then
        return false, "task_id is required"
    end

    if not schedule_calculator then
        return false, "schedule_calculator is required"
    end

    local db, err = get_db()
    if err then
        return false, err
    end

    local tx, tx_err = db:begin()
    if tx_err then
        db:release()
        return false, "Failed to begin transaction: " .. tx_err
    end

    -- Get current schedule data
    local query = sql.builder.select("*"):from("schedules"):where("id = ?", task_id)
    local executor = query:run_with(tx)
    local results, query_err = executor:query()

    if query_err then
        tx:rollback()
        db:release()
        return false, "Failed to get schedule: " .. query_err
    end

    if not results or #results == 0 then
        tx:rollback()
        db:release()
        return false, "Schedule not found"
    end

    local schedule_data = row_to_schedule_data(results[1])

    -- Calculate next run time based on schedule type
    local next_run_time, calc_err
    if schedule_data.schedule_type == SCHEDULE_TYPES.ONCE then
        -- Once schedules should be disabled, not rescheduled
        tx:rollback()
        db:release()
        return false, "Cannot reschedule 'once' schedule - should be disabled instead"
    elseif schedule_data.schedule_type == SCHEDULE_TYPES.INTERVAL then
        next_run_time, calc_err = schedule_calculator.next_interval_run(
            schedule_data.schedule_expression,
            schedule_data.last_run_at,
            schedule_data.created_at
        )
    elseif schedule_data.schedule_type == SCHEDULE_TYPES.TICKER then
        next_run_time, calc_err = schedule_calculator.next_ticker_run(
            schedule_data.schedule_expression,
            schedule_data.last_run_at,
            schedule_data.created_at
        )
    elseif schedule_data.schedule_type == SCHEDULE_TYPES.CRON then
        next_run_time, calc_err = schedule_calculator.next_cron_run(
            schedule_data.schedule_expression,
            schedule_data.last_run_at,
            schedule_data.created_at
        )
    else
        tx:rollback()
        db:release()
        return false, "Unknown schedule type: " .. schedule_data.schedule_type
    end

    if calc_err then
        tx:rollback()
        db:release()
        return false, "Failed to calculate next run time: " .. calc_err
    end

    -- Update schedule for next run
    local now_time = time.now():utc() -- Always use UTC
    local update_query = sql.builder.update("schedules")
        :set("status", STATUS.SCHEDULED)
        :set("next_run_at", encode_time_for_db(next_run_time))
        :set("last_run_at", encode_time_for_db(now_time))
        :set("picked", false)
        :set("picked_by", sql.as.null())
        :set("picked_at", sql.as.null())
        :set("retry_count", 0)
        :set("consecutive_failures", 0)
        :set("last_error", sql.as.null())
        :set("updated_at", encode_time_for_db(now_time))
        :where("id = ?", task_id)

    local update_executor = update_query:run_with(tx)
    local update_result, update_err = update_executor:exec()

    if update_err then
        tx:rollback()
        db:release()
        return false, "Failed to reschedule task: " .. update_err
    end

    -- Commit transaction
    local commit_ok, commit_err = tx:commit()
    if commit_err then
        tx:rollback()
        db:release()
        return false, "Failed to commit transaction: " .. commit_err
    end

    db:release()
    return update_result.rows_affected > 0, nil
end

---Disable a schedule permanently
---@param task_id string
---@param reason string Reason for disabling
---@return boolean, string|nil -- success, error
function schedule_repo.disable_schedule(task_id, reason)
    if not task_id or task_id == "" then
        return false, "task_id is required"
    end

    if not reason or reason == "" then
        reason = "Disabled by system"
    end

    local db, err = get_db()
    if err then
        return false, err
    end

    local now_time = time.now():utc() -- Always use UTC
    local update_query = sql.builder.update("schedules")
        :set("enabled", false)
        :set("status", STATUS.DISABLED)
        :set("picked", false)
        :set("picked_by", sql.as.null())
        :set("picked_at", sql.as.null())
        :set("last_error", reason)
        :set("updated_at", encode_time_for_db(now_time))
        :where("id = ?", task_id)

    local executor = update_query:run_with(db)
    local result, update_err = executor:exec()
    db:release()

    if update_err then
        return false, "Failed to disable schedule: " .. update_err
    end

    return result.rows_affected > 0, nil
end

---Reset a task for retry (keep current next_run_at)
---@param task_id string
---@return boolean, string|nil -- success, error
function schedule_repo.reset_for_retry(task_id)
    if not task_id or task_id == "" then
        return false, "task_id is required"
    end

    local db, err = get_db()
    if err then
        return false, err
    end

    local now_time = time.now():utc() -- Always use UTC
    local update_query = sql.builder.update("schedules")
        :set("status", STATUS.SCHEDULED)
        :set("picked", false)
        :set("picked_by", sql.as.null())
        :set("picked_at", sql.as.null())
        :set("updated_at", encode_time_for_db(now_time))
        :where("id = ?", task_id)

    local executor = update_query:run_with(db)
    local result, update_err = executor:exec()
    db:release()

    if update_err then
        return false, "Failed to reset task for retry: " .. update_err
    end

    return result.rows_affected > 0, nil
end

---Update task execution counters and error info
---@param task_id string
---@param is_success boolean
---@param error_message string|nil
---@return boolean, string|nil -- success, error
function schedule_repo.update_execution_result(task_id, is_success, error_message)
    if not task_id or task_id == "" then
        return false, "task_id is required"
    end

    local db, err = get_db()
    if err then
        return false, err
    end

    local now_time = time.now():utc() -- Always use UTC
    local update_query = sql.builder.update("schedules")
        :set("last_run_at", encode_time_for_db(now_time))
        :set("updated_at", encode_time_for_db(now_time))
        :where("id = ?", task_id)

    if is_success then
        -- Reset failure counters on success
        update_query = update_query
            :set("consecutive_failures", 0)
            :set("last_error", sql.as.null())
    else
        -- Increment failure counters and set error
        update_query = update_query
            :set("consecutive_failures", sql.builder.expr("consecutive_failures + 1"))
            :set("retry_count", sql.builder.expr("retry_count + 1"))
            :set("last_error", error_message or "Unknown error")
    end

    local executor = update_query:run_with(db)
    local result, update_err = executor:exec()
    db:release()

    if update_err then
        return false, "Failed to update execution result: " .. update_err
    end

    return result.rows_affected > 0, nil
end

---Clean up tasks that have been picked for too long using per-task timeout_seconds
---@return integer, string|nil -- released_count, error
function schedule_repo.cleanup_stuck_tasks()
    local db, err = get_db()
    if err then
        return 0, err
    end

    local db_type = get_database_type()
    local now_time = time.now():utc() -- Always use UTC

    local update_query

    if db_type == sql.type.POSTGRES then
        -- PostgreSQL: Use EXTRACT to get epoch seconds and compare
        local now_unix = now_time:unix()
        update_query = sql.builder.update("schedules")
            :set("picked", false)
            :set("picked_by", sql.as.null())
            :set("picked_at", sql.as.null())
            :set("status", STATUS.SCHEDULED)
            :set("last_error", "Task timeout - worker may have died")
            :set("updated_at", encode_time_for_db(now_time))
            :where("picked = ?", true)
            :where("status = ?", STATUS.EXECUTING)
            :where(sql.builder.expr("(? - EXTRACT(EPOCH FROM picked_at)) > timeout_seconds", now_unix))
    else
        -- SQLite: Direct comparison with Unix timestamps
        local now_unix = now_time:unix()
        update_query = sql.builder.update("schedules")
            :set("picked", false)
            :set("picked_by", sql.as.null())
            :set("picked_at", sql.as.null())
            :set("status", STATUS.SCHEDULED)
            :set("last_error", "Task timeout - worker may have died")
            :set("updated_at", encode_time_for_db(now_time))
            :where("picked = ?", true)
            :where("status = ?", STATUS.EXECUTING)
            :where(sql.builder.expr("(? - picked_at) > timeout_seconds", now_unix))
    end

    local executor = update_query:run_with(db)
    local result, update_err = executor:exec()
    db:release()

    if update_err then
        return 0, "Failed to cleanup stuck tasks: " .. update_err
    end

    return result.rows_affected, nil
end

---Delete old completed and failed tasks
---@param completed_retention_hours integer How long to keep completed tasks (default 24h)
---@param failed_retention_hours integer How long to keep failed tasks (default 72h)
---@return integer, string|nil -- deleted_count, error
function schedule_repo.cleanup_old_tasks(completed_retention_hours, failed_retention_hours)
    completed_retention_hours = completed_retention_hours or 24
    failed_retention_hours = failed_retention_hours or 72

    local db, err = get_db()
    if err then
        return 0, err
    end

    local now = time.now():utc() -- Always use UTC
    local completed_cutoff = now:add(-completed_retention_hours * 3600 * 1000)
    local failed_cutoff = now:add(-failed_retention_hours * 3600 * 1000)

    -- Delete old completed tasks
    local delete_completed = sql.builder.delete("schedules")
        :where("status = ?", STATUS.COMPLETED)
        :where("updated_at < ?", encode_time_for_db(completed_cutoff))

    local completed_executor = delete_completed:run_with(db)
    local completed_result, completed_err = completed_executor:exec()

    local completed_deleted = 0
    if not completed_err then
        completed_deleted = completed_result.rows_affected or 0
    end

    -- Delete old failed tasks
    local delete_failed = sql.builder.delete("schedules")
        :where("status = ?", STATUS.FAILED)
        :where("updated_at < ?", encode_time_for_db(failed_cutoff))

    local failed_executor = delete_failed:run_with(db)
    local failed_result, failed_err = failed_executor:exec()

    local failed_deleted = 0
    if not failed_err then
        failed_deleted = failed_result.rows_affected or 0
    end

    db:release()

    local total_deleted = completed_deleted + failed_deleted
    local combined_error = nil
    if completed_err and failed_err then
        combined_error = "Completed: " .. completed_err .. "; Failed: " .. failed_err
    elseif completed_err then
        combined_error = "Completed cleanup failed: " .. completed_err
    elseif failed_err then
        combined_error = "Failed cleanup failed: " .. failed_err
    end

    return total_deleted, combined_error
end

---Delete old disabled schedules
---@param disabled_retention_hours integer How long to keep disabled schedules (default 168h = 7 days)
---@return integer, string|nil -- deleted_count, error
function schedule_repo.cleanup_disabled_schedules(disabled_retention_hours)
    disabled_retention_hours = disabled_retention_hours or 168 -- 7 days

    local db, err = get_db()
    if err then
        return 0, err
    end

    local now = time.now():utc() -- Always use UTC
    local disabled_cutoff = now:add(-disabled_retention_hours * 3600 * 1000)

    -- Delete old disabled schedules
    local delete_disabled = sql.builder.delete("schedules")
        :where("status = ?", STATUS.DISABLED)
        :where("enabled = ?", false)
        :where("updated_at < ?", encode_time_for_db(disabled_cutoff))

    local executor = delete_disabled:run_with(db)
    local result, delete_err = executor:exec()
    db:release()

    if delete_err then
        return 0, "Failed to cleanup disabled schedules: " .. delete_err
    end

    return result.rows_affected, nil
end

-- =============================================================================
-- UTILITY OPERATIONS
-- =============================================================================

---Count schedules matching filters
---@param filters ScheduleFilters|nil
---@return integer, string|nil -- count, error
function schedule_repo.count(filters)
    filters = filters or {}

    local db, err = get_db()
    if err then
        return 0, err
    end

    local query = sql.builder.select("COUNT(*) as count"):from("schedules")

    -- Apply filters
    if filters.status then
        query = query:where("status = ?", filters.status)
    end
    if filters.enabled ~= nil then
        query = query:where("enabled = ?", filters.enabled)
    end
    if filters.class then
        query = query:where("class = ?", filters.class)
    end
    if filters.task_implementation_id then
        query = query:where("task_implementation_id = ?", filters.task_implementation_id)
    end
    if filters.schedule_type then
        query = query:where("schedule_type = ?", filters.schedule_type)
    end
    if filters.user_id then
        query = query:where("user_id = ?", filters.user_id)
    end
    if filters.actor_id then
        query = query:where("actor_id = ?", filters.actor_id)
    end
    if filters.actor_scope then
        query = query:where("actor_scope = ?", filters.actor_scope)
    end

    local executor = query:run_with(db)
    local results, query_err = executor:query()
    db:release()

    if query_err then
        return 0, "Failed to count schedules: " .. query_err
    end

    return results[1].count or 0, nil
end

-- Export constants and module
schedule_repo.STATUS = STATUS
schedule_repo.SCHEDULE_TYPES = SCHEDULE_TYPES

return schedule_repo
