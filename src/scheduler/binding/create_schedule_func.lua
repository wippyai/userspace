local security = require("security")
local time = require("time")
local schedule_repo = require("schedule_repo")
local schedule_calculator = require("schedule_calculator")

-- Constants
local DEFAULT_ACTOR_SCOPE = "wippy.security:process"

local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_SCHEDULE_TYPE = "schedule_type is required and must be a non-empty string",
    MISSING_SCHEDULE_EXPRESSION = "schedule_expression is required and must be a non-empty string",
    MISSING_TASK_IMPLEMENTATION_ID = "task_implementation_id is required and must be a non-empty string",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID",
    INVALID_TASK_CONTEXT = "task_context must be a table",
    INVALID_TASK_ARGS = "task_args must be a table",
    INVALID_TIMEOUT = "timeout_seconds must be a positive integer",
    INVALID_MAX_RETRIES = "max_retries must be a non-negative integer",
    INVALID_TASK_ID = "task_id must be a non-empty string if provided"
}

local BUSINESS_ERRORS = {
    SCHEDULE_CALCULATION_FAILED = "Failed to calculate next run time",
    CREATE_FAILED = "Failed to create scheduled task"
}

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.schedule_type or type(request_dto.schedule_type) ~= "string" or request_dto.schedule_type == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_SCHEDULE_TYPE }
    end

    if not request_dto.schedule_expression or type(request_dto.schedule_expression) ~= "string" or request_dto.schedule_expression == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_SCHEDULE_EXPRESSION }
    end

    if not request_dto.task_implementation_id or type(request_dto.task_implementation_id) ~= "string" or request_dto.task_implementation_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_TASK_IMPLEMENTATION_ID }
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

    -- Optional field validation
    local task_context = request_dto.task_context or {}
    if type(task_context) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_TASK_CONTEXT }
    end

    local task_args = request_dto.task_args or {}
    if type(task_args) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_TASK_ARGS }
    end

    local timeout_seconds = request_dto.timeout_seconds or 3600
    if type(timeout_seconds) ~= "number" or timeout_seconds <= 0 then
        return { success = false, error = VALIDATION_ERRORS.INVALID_TIMEOUT }
    end

    local max_retries = request_dto.max_retries or 3
    if type(max_retries) ~= "number" or max_retries < 0 then
        return { success = false, error = VALIDATION_ERRORS.INVALID_MAX_RETRIES }
    end

    -- Task ID validation
    local task_id = request_dto.task_id
    if task_id and (type(task_id) ~= "string" or task_id == "") then
        return { success = false, error = VALIDATION_ERRORS.INVALID_TASK_ID }
    end

    -- Get current security scope for task execution context
    local actor_scope = DEFAULT_ACTOR_SCOPE -- Default scope for now
    local current_scope = security.scope()
    if current_scope and current_scope.id then
        actor_scope = current_scope:id()
    end

    -- Calculate next run time based on schedule type
    local next_run_time, calc_err
    local now = time.now()

    if request_dto.schedule_type == schedule_repo.SCHEDULE_TYPES.ONCE then
        next_run_time, calc_err = schedule_calculator.next_once_run(request_dto.schedule_expression, nil, nil)
    elseif request_dto.schedule_type == schedule_repo.SCHEDULE_TYPES.INTERVAL then
        next_run_time, calc_err = schedule_calculator.next_interval_run(request_dto.schedule_expression, nil, now:format(time.RFC3339))
    elseif request_dto.schedule_type == schedule_repo.SCHEDULE_TYPES.TICKER then
        next_run_time, calc_err = schedule_calculator.next_ticker_run(request_dto.schedule_expression, nil, now:format(time.RFC3339))
    elseif request_dto.schedule_type == schedule_repo.SCHEDULE_TYPES.CRON then
        next_run_time, calc_err = schedule_calculator.next_cron_run(request_dto.schedule_expression, nil, nil)
    else
        return { success = false, error = "Unsupported schedule_type: " .. request_dto.schedule_type }
    end

    if calc_err then
        return { success = false, error = BUSINESS_ERRORS.SCHEDULE_CALCULATION_FAILED .. ": " .. calc_err }
    end

    -- Parse next run time
    local next_run_time_obj, parse_err = time.parse(time.RFC3339, next_run_time :: string)
    if parse_err then
        return { success = false, error = BUSINESS_ERRORS.SCHEDULE_CALCULATION_FAILED .. ": " .. parse_err }
    end

    -- Create task data for repository
    local task_data = {
        task_id = task_id, -- May be nil, repo will generate if needed
        description = request_dto.description,
        class = request_dto.class or "user",
        user_id = user_id,
        task_implementation_id = request_dto.task_implementation_id,
        task_context = task_context,
        task_args = task_args,
        schedule_type = request_dto.schedule_type,
        schedule_expression = request_dto.schedule_expression,
        next_run_at = next_run_time_obj,
        timeout_seconds = timeout_seconds,
        max_retries = max_retries,
        enabled = request_dto.enabled ~= false, -- Default to true
        -- Security context for task execution
        actor_id = user_id,
        actor_scope = actor_scope,
        actor_metadata = actor:meta() or {}
    }

    -- Create the scheduled task
    local created_task_id, create_err = schedule_repo.create(task_data)
    if create_err then
        return { success = false, error = BUSINESS_ERRORS.CREATE_FAILED .. ": " .. create_err }
    end

    -- Success response
    return {
        success = true,
        task_id = created_task_id,
        next_run_at = next_run_time
    }
end

return { handle = handle }