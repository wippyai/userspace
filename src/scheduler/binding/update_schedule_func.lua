local security = require("security")
local time = require("time")
local schedule_repo = require("schedule_repo")
local schedule_calculator = require("schedule_calculator")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_TASK_ID = "task_id is required and must be a non-empty string",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID",
    INVALID_TASK_CONTEXT = "task_context must be a table",
    INVALID_TASK_ARGS = "task_args must be a table",
    INVALID_TIMEOUT = "timeout_seconds must be a positive integer",
    INVALID_MAX_RETRIES = "max_retries must be a non-negative integer",
    NO_UPDATES = "At least one field must be provided for update"
}

local BUSINESS_ERRORS = {
    NOT_FOUND = "Task not found or access denied",
    UPDATE_FAILED = "Failed to update scheduled task",
    SCHEDULE_CALCULATION_FAILED = "Failed to calculate next run time"
}

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.task_id or type(request_dto.task_id) ~= "string" or request_dto.task_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_TASK_ID }
    end

    -- Security context validation
    local actor = security.actor()
    if not actor then
        return { success = false, error = VALIDATION_ERRORS.NO_ACTOR }
    end

    local user_id = actor:id()
    if not user_id or user_id == "" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_ACTOR }
    end

    -- Check that at least one update field is provided
    local has_updates = false
    local updateable_fields = {
        "description", "schedule_expression", "task_context", "task_args",
        "timeout_seconds", "max_retries", "enabled"
    }

    for _, field in ipairs(updateable_fields) do
        if request_dto[field] ~= nil then
            has_updates = true
            break
        end
    end

    if not has_updates then
        return { success = false, error = VALIDATION_ERRORS.NO_UPDATES }
    end

    -- Validate update fields
    if request_dto.task_context and type(request_dto.task_context) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_TASK_CONTEXT }
    end

    if request_dto.task_args and type(request_dto.task_args) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_TASK_ARGS }
    end

    if request_dto.timeout_seconds and (type(request_dto.timeout_seconds) ~= "number" or request_dto.timeout_seconds <= 0) then
        return { success = false, error = VALIDATION_ERRORS.INVALID_TIMEOUT }
    end

    if request_dto.max_retries and (type(request_dto.max_retries) ~= "number" or request_dto.max_retries < 0) then
        return { success = false, error = VALIDATION_ERRORS.INVALID_MAX_RETRIES }
    end

    -- First check if task exists and user has access
    local existing_task, get_err = schedule_repo.get(request_dto.task_id)
    if get_err then
        return { success = false, error = BUSINESS_ERRORS.NOT_FOUND }
    end

    -- Check if user owns the task (basic access control)
    if existing_task.user_id ~= user_id then
        return { success = false, error = BUSINESS_ERRORS.NOT_FOUND }
    end

    -- Build updates object
    local updates = {}
    local schedule_changed = false

    if request_dto.description then
        updates.description = request_dto.description
    end

    if request_dto.schedule_expression then
        updates.schedule_expression = request_dto.schedule_expression
        schedule_changed = true
    end

    if request_dto.task_context then
        updates.task_context = request_dto.task_context
    end

    if request_dto.task_args then
        updates.task_args = request_dto.task_args
    end

    if request_dto.timeout_seconds then
        updates.timeout_seconds = request_dto.timeout_seconds
    end

    if request_dto.max_retries then
        updates.max_retries = request_dto.max_retries
    end

    if request_dto.enabled ~= nil then
        updates.enabled = request_dto.enabled
    end

    -- If schedule expression changed, recalculate next run time
    local new_next_run_at = nil
    if schedule_changed then
        local schedule_expression = request_dto.schedule_expression
        local schedule_type = existing_task.schedule_type

        local next_run_time, calc_err
        if schedule_type == schedule_repo.SCHEDULE_TYPES.ONCE then
            next_run_time, calc_err = schedule_calculator.next_once_run(schedule_expression, existing_task.last_run_at, nil)
        elseif schedule_type == schedule_repo.SCHEDULE_TYPES.INTERVAL then
            next_run_time, calc_err = schedule_calculator.next_interval_run(schedule_expression, existing_task.last_run_at, existing_task.created_at)
        elseif schedule_type == schedule_repo.SCHEDULE_TYPES.TICKER then
            next_run_time, calc_err = schedule_calculator.next_ticker_run(schedule_expression, existing_task.last_run_at, existing_task.created_at)
        elseif schedule_type == schedule_repo.SCHEDULE_TYPES.CRON then
            next_run_time, calc_err = schedule_calculator.next_cron_run(schedule_expression, existing_task.last_run_at, nil)
        else
            return { success = false, error = "Unsupported schedule_type: " .. schedule_type }
        end

        if calc_err then
            return { success = false, error = BUSINESS_ERRORS.SCHEDULE_CALCULATION_FAILED .. ": " .. calc_err }
        end

        -- Parse next run time
        local next_run_time_obj, parse_err = time.parse(time.RFC3339, next_run_time :: string)
        if parse_err then
            return { success = false, error = BUSINESS_ERRORS.SCHEDULE_CALCULATION_FAILED .. ": " .. parse_err }
        end

        updates.next_run_at = next_run_time_obj
        new_next_run_at = next_run_time
    end

    -- Update the scheduled task
    local update_success, update_err = schedule_repo.update(request_dto.task_id, updates)
    if update_err then
        return { success = false, error = BUSINESS_ERRORS.UPDATE_FAILED .. ": " .. update_err }
    end

    -- Build success response
    local response = {
        success = true,
        task_id = request_dto.task_id,
        changes_made = update_success
    }

    -- Include new next run time if schedule was changed
    if new_next_run_at then
        response.next_run_at = new_next_run_at
    end

    return response
end

return { handle = handle }