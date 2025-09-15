local security = require("security")
local schedule_repo = require("schedule_repo")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_TASK_ID = "task_id is required and must be a non-empty string",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID"
}

local BUSINESS_ERRORS = {
    NOT_FOUND = "Task not found or access denied"
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

    -- Get the scheduled task
    local task, get_err = schedule_repo.get(request_dto.task_id)
    if get_err then
        return { success = false, error = BUSINESS_ERRORS.NOT_FOUND }
    end

    -- Check if user owns the task (basic access control)
    if task.user_id ~= user_id then
        return { success = false, error = BUSINESS_ERRORS.NOT_FOUND }
    end

    -- Success response with task data
    return {
        success = true,
        task_id = task.id,
        description = task.description,
        class = task.class,
        schedule_type = task.schedule_type,
        schedule_expression = task.schedule_expression,
        task_implementation_id = task.task_implementation_id,
        task_context = task.task_context,
        task_args = task.task_args,
        status = task.status,
        enabled = task.enabled,
        next_run_at = task.next_run_at,
        last_run_at = task.last_run_at,
        retry_count = task.retry_count,
        max_retries = task.max_retries,
        consecutive_failures = task.consecutive_failures,
        last_error = task.last_error,
        timeout_seconds = task.timeout_seconds,
        created_at = task.created_at,
        updated_at = task.updated_at
    }
end

return { handle = handle }