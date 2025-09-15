local time = require("time")
local uuid = require("uuid")
local logger = require("logger")
local schedule_repo = require("schedule_repo")

-- Constants
local CONST = {
    COMPLETED_RETENTION_HOURS = 24,  -- How long to keep completed tasks
    FAILED_RETENTION_HOURS = 72,    -- How long to keep failed tasks
    DISABLED_RETENTION_HOURS = 168, -- How long to keep disabled schedules (7 days)
}

---@class CleanupStats
---@field start_time table
---@field stuck_tasks_cleaned integer
---@field old_tasks_cleaned integer
---@field disabled_schedules_cleaned integer
---@field total_operations integer
---@field operations_succeeded integer
---@field operations_failed integer

local function run(worker_id)
    worker_id = worker_id or ("cleanup_" .. uuid.v4():sub(1, 8))
    local log = logger:named("scheduler.cleanup"):with({ worker_id = worker_id })

    log:debug("Cleanup worker starting")

    ---@type CleanupStats
    local stats = {
        start_time = time.now(),
        stuck_tasks_cleaned = 0,
        old_tasks_cleaned = 0,
        disabled_schedules_cleaned = 0,
        total_operations = 0,
        operations_succeeded = 0,
        operations_failed = 0
    }

    ---Helper to run a cleanup operation and track stats
    ---@param operation_name string Name of the operation for logging
    ---@param operation_func function Function that returns count, error
    ---@return integer count, string|nil error
    local function run_cleanup_operation(operation_name, operation_func)
        stats.total_operations = stats.total_operations + 1

        log:debug("Running " .. operation_name)
        local count, err = operation_func()

        if err then
            stats.operations_failed = stats.operations_failed + 1
            log:debug("Failed " .. operation_name, { error = err })
            return 0, err
        else
            stats.operations_succeeded = stats.operations_succeeded + 1
            if count > 0 then
                log:debug("Completed " .. operation_name, { count = count })
            else
                log:debug("No items found for " .. operation_name)
            end
            return count, nil
        end
    end

    -- 1. Clean up stuck tasks (highest priority)
    local stuck_count, stuck_err = run_cleanup_operation(
        "stuck task cleanup",
        function()
            return schedule_repo.cleanup_stuck_tasks()
        end
    )
    stats.stuck_tasks_cleaned = stuck_count

    -- Continue with other cleanup operations even if stuck task cleanup fails
    if stuck_err then
        log:debug("Stuck task cleanup failed, continuing with other operations", { error = stuck_err })
    end

    -- 2. Clean up old completed and failed tasks
    local old_count, old_err = run_cleanup_operation(
        "old task cleanup",
        function()
            return schedule_repo.cleanup_old_tasks(
                CONST.COMPLETED_RETENTION_HOURS,
                CONST.FAILED_RETENTION_HOURS
            )
        end
    )
    stats.old_tasks_cleaned = old_count

    if old_err then
        log:debug("Old task cleanup failed, continuing with other operations", { error = old_err })
    end

    -- 3. Clean up old disabled schedules
    local disabled_count, disabled_err = run_cleanup_operation(
        "disabled schedule cleanup",
        function()
            return schedule_repo.cleanup_disabled_schedules(CONST.DISABLED_RETENTION_HOURS)
        end
    )
    stats.disabled_schedules_cleaned = disabled_count

    if disabled_err then
        log:debug("Disabled schedule cleanup failed", { error = disabled_err })
    end

    -- Calculate final results
    local duration = time.now():sub(stats.start_time)
    local total_cleaned = stats.stuck_tasks_cleaned + stats.old_tasks_cleaned + stats.disabled_schedules_cleaned
    local success_rate = stats.total_operations > 0 and (stats.operations_succeeded / stats.total_operations * 100) or 0

    -- Determine overall success
    local overall_success = stats.operations_succeeded > 0 or stats.operations_failed == 0
    local primary_error = nil

    -- If stuck task cleanup failed, that's the most critical
    if stuck_err then
        primary_error = "Critical: Stuck task cleanup failed - " .. stuck_err
    elseif stats.operations_failed == stats.total_operations then
        primary_error = "All cleanup operations failed"
    end

    log:info("Cleanup completed", {
        total_cleaned = total_cleaned,
        success = overall_success
    })

    return {
        worker_id = worker_id,
        success = overall_success,
        error = primary_error,
        stats = stats,
        summary = {
            total_items_cleaned = total_cleaned,
            operations_completed = stats.operations_succeeded,
            operations_failed = stats.operations_failed,
            duration_ms = duration:milliseconds()
        }
    }
end

return { run = run }