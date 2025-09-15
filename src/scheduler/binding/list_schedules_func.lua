local security = require("security")
local schedule_repo = require("schedule_repo")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table or nil",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID",
    INVALID_FILTERS = "filters must be a table",
    INVALID_PAGINATION = "pagination must be a table",
    INVALID_ORDERING = "ordering must be a table"
}

local PAGINATION_LIMITS = {
    MIN_LIMIT = 1,
    MAX_LIMIT = 100,
    DEFAULT_LIMIT = 50,
    MIN_OFFSET = 0,
    DEFAULT_OFFSET = 0
}

local ORDERING_OPTIONS = {
    VALID_FIELDS = { "created_at", "updated_at", "next_run_at" },
    VALID_DIRECTIONS = { "ASC", "DESC" },
    DEFAULT_FIELD = "created_at",
    DEFAULT_DIRECTION = "DESC"
}

local function validate_pagination(pagination)
    local limit = pagination.limit or PAGINATION_LIMITS.DEFAULT_LIMIT
    local offset = pagination.offset or PAGINATION_LIMITS.DEFAULT_OFFSET

    if type(limit) ~= "number" or limit < PAGINATION_LIMITS.MIN_LIMIT or limit > PAGINATION_LIMITS.MAX_LIMIT then
        return nil, nil,
            "pagination.limit must be between " .. PAGINATION_LIMITS.MIN_LIMIT .. " and " .. PAGINATION_LIMITS.MAX_LIMIT
    end

    if type(offset) ~= "number" or offset < PAGINATION_LIMITS.MIN_OFFSET then
        return nil, nil, "pagination.offset must be >= " .. PAGINATION_LIMITS.MIN_OFFSET
    end

    return limit, offset, nil
end

local function validate_ordering(ordering)
    local field = ordering.field or ORDERING_OPTIONS.DEFAULT_FIELD
    local direction = ordering.direction or ORDERING_OPTIONS.DEFAULT_DIRECTION

    -- Check if field is valid
    local valid_field = false
    for _, valid in ipairs(ORDERING_OPTIONS.VALID_FIELDS) do
        if field == valid then
            valid_field = true
            break
        end
    end
    if not valid_field then
        return nil, nil, "ordering.field must be one of: " .. table.concat(ORDERING_OPTIONS.VALID_FIELDS, ", ")
    end

    -- Check if direction is valid
    local valid_direction = false
    for _, valid in ipairs(ORDERING_OPTIONS.VALID_DIRECTIONS) do
        if direction == valid then
            valid_direction = true
            break
        end
    end
    if not valid_direction then
        return nil, nil, "ordering.direction must be one of: " .. table.concat(ORDERING_OPTIONS.VALID_DIRECTIONS, ", ")
    end

    return field, direction, nil
end

local function handle(request_dto)
    -- Input validation (request_dto is optional)
    if request_dto == nil then
        request_dto = {}
    end

    if type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
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

    -- Extract and validate request sections
    local filters = request_dto.filters or {}
    local pagination = request_dto.pagination or {}
    local ordering = request_dto.ordering or {}

    if type(filters) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_FILTERS }
    end

    if type(pagination) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_PAGINATION }
    end

    if type(ordering) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_ORDERING }
    end

    -- Validate pagination parameters
    local limit, offset, pagination_error = validate_pagination(pagination)
    if pagination_error then
        return { success = false, error = pagination_error }
    end

    -- Validate ordering parameters
    local order_field, order_direction, ordering_error = validate_ordering(ordering)
    if ordering_error then
        return { success = false, error = ordering_error }
    end

    -- Build filter criteria for repository
    local repo_filters = {
        user_id = user_id -- Always filter by current user
    }

    -- Apply additional filters from request
    if filters.status then
        repo_filters.status = filters.status
    end

    if filters.enabled ~= nil then
        repo_filters.enabled = filters.enabled
    end

    if filters.class then
        repo_filters.class = filters.class
    end

    if filters.task_implementation_id then
        repo_filters.task_implementation_id = filters.task_implementation_id
    end

    if filters.schedule_type then
        repo_filters.schedule_type = filters.schedule_type
    end

    -- List schedules using repository
    local schedules, list_err = schedule_repo.list(repo_filters, {
        limit = limit,
        offset = offset,
        order_by = order_field,
        order_direction = order_direction
    })

    if list_err then
        return { success = false, error = "Failed to list schedules: " .. list_err }
    end

    -- Get total count for pagination
    local total_count, count_err = schedule_repo.count(repo_filters)
    if count_err then
        return { success = false, error = "Failed to count schedules: " .. count_err }
    end

    -- Determine if there are more results
    local has_more = (offset + #schedules) < total_count

    -- Transform repository data to contract format
    local contract_schedules = {}
    for i, task in ipairs(schedules) do
        contract_schedules[i] = {
            task_id = task.id,
            description = task.description,
            class = task.class,
            schedule_type = task.schedule_type,
            schedule_expression = task.schedule_expression,
            task_implementation_id = task.task_implementation_id,
            status = task.status,
            enabled = task.enabled,
            next_run_at = task.next_run_at,
            last_run_at = task.last_run_at,
            retry_count = task.retry_count,
            consecutive_failures = task.consecutive_failures,
            created_at = task.created_at,
            updated_at = task.updated_at
        }
    end

    -- Success response
    return {
        success = true,
        schedules = contract_schedules,
        total_count = total_count,
        has_more = has_more
    }
end

return { handle = handle }
