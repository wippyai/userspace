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
    DELETE_FAILED = "Failed to delete scheduled task",
    ACCESS_DENIED = "Task not found or insufficient access to delete"
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

    -- First check if task exists and user has access
    local existing_task, get_err = schedule_repo.get(request_dto.task_id)
    if get_err then
        return { success = false, error = BUSINESS_ERRORS.ACCESS_DENIED }
    end

    -- Check if user owns the task (basic access control)
    if existing_task.user_id ~= user_id then
        return { success = false, error = BUSINESS_ERRORS.ACCESS_DENIED }
    end

    -- Delete the scheduled task
    local deleted, delete_err = schedule_repo.delete(request_dto.task_id)
    if delete_err then
        return { success = false, error = BUSINESS_ERRORS.DELETE_FAILED .. ": " .. delete_err }
    end

    -- Success response
    return {
        success = true,
        task_id = request_dto.task_id,
        deleted = deleted
    }
end

return { handle = handle }