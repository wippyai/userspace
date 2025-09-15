local security = require("security")
local component_reader = require("component_reader")

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
    VALID_FIELDS = {"created_at", "updated_at"},
    VALID_DIRECTIONS = {"ASC", "DESC"},
    DEFAULT_FIELD = "created_at",
    DEFAULT_DIRECTION = "DESC"
}

local function validate_pagination(pagination)
    local limit = pagination.limit or PAGINATION_LIMITS.DEFAULT_LIMIT
    local offset = pagination.offset or PAGINATION_LIMITS.DEFAULT_OFFSET

    if type(limit) ~= "number" or limit < PAGINATION_LIMITS.MIN_LIMIT or limit > PAGINATION_LIMITS.MAX_LIMIT then
        return nil, nil, "pagination.limit must be between " .. PAGINATION_LIMITS.MIN_LIMIT .. " and " .. PAGINATION_LIMITS.MAX_LIMIT
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

local function validate_impl_ids(impl_ids)
    for i, impl_id in ipairs(impl_ids) do
        if type(impl_id) ~= "string" or impl_id == "" then
            return "filters.impl_ids[" .. i .. "] must be a non-empty string"
        end
    end
    return nil
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

    -- Build component reader with user filter and options
    local reader = component_reader.new()
        :with_user(user_id)
        :include_options({
            meta = true,
            private_context = false  -- Never expose private context in listings
        })
        :limit(limit, offset)
        :order_by(order_field, order_direction)

    -- Apply filters
    if filters.impl_ids and type(filters.impl_ids) == "table" and #filters.impl_ids > 0 then
        local impl_ids_error = validate_impl_ids(filters.impl_ids)
        if impl_ids_error then
            return { success = false, error = impl_ids_error }
        end
        reader = reader:with_impl_ids(filters.impl_ids)
    end

    if filters.meta and type(filters.meta) == "table" then
        reader = reader:with_meta(filters.meta)
    end

    if filters.access_mask and type(filters.access_mask) == "number" and filters.access_mask > 0 then
        reader = reader:with_access_mask(filters.access_mask)
    end

    -- Get components and total count
    local components = reader:all()
    local total_count = reader:count()

    -- Determine if there are more results
    local has_more = (offset + #components) < total_count

    -- Success response
    return {
        components = components,
        total_count = total_count,
        has_more = has_more,
        success = true
    }
end

return { handle = handle }