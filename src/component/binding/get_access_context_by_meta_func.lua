local security = require("security")
local component_reader = require("component_reader")
local ops = require("ops")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_META = "meta is required and must be a non-empty table",
    INVALID_META = "meta must contain string key-value pairs only",
    INVALID_ACCESS_MASK = "access_mask must be a non-negative integer",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID"
}

local BUSINESS_ERRORS = {
    NOT_FOUND = "No component found matching the specified metadata and access requirements",
    MULTIPLE_FOUND = "Multiple components found matching the specified metadata. Use get_access_context with a specific component_id instead"
}

local function validate_meta_filters(meta)
    if not meta or type(meta) ~= "table" then
        return VALIDATION_ERRORS.MISSING_META
    end

    -- Check if empty
    local has_entries = false
    for key, value in pairs(meta) do
        if type(key) ~= "string" or type(value) ~= "string" then
            return VALIDATION_ERRORS.INVALID_META
        end
        has_entries = true
    end

    if not has_entries then
        return VALIDATION_ERRORS.MISSING_META
    end

    return nil
end

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    -- Validate meta filters
    local meta_error = validate_meta_filters(request_dto.meta)
    if meta_error then
        return { success = false, error = meta_error }
    end

    -- Validate access_mask (defaults to READ if not provided)
    local access_mask = request_dto.access_mask or ops.ACCESS.READ
    if type(access_mask) ~= "number" or access_mask < 0 then
        return { success = false, error = VALIDATION_ERRORS.INVALID_ACCESS_MASK }
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

    -- Build component reader query
    local reader = component_reader.new()
        :with_user(user_id)
        :with_meta(request_dto.meta)
        :with_access_mask(access_mask)
        :include_options({
            meta = false,
            private_context = true, -- We need the private context for execution
            access_level = true     -- We need the user's access level
        })
        :limit(2)  -- We only need to know if there are 0, 1, or 2+ results

    -- Execute query
    local components = reader:all()

    -- Handle results based on count
    if #components == 0 then
        return { success = false, error = BUSINESS_ERRORS.NOT_FOUND }
    end

    if #components > 1 then
    print(require("json").encode(components))
        return { success = false, error = BUSINESS_ERRORS.MULTIPLE_FOUND }
    end

    -- Exactly one component found
    local component = components[1]

    -- Success response with access context (same format as get_access_context)
    return {
        id = component.component_id,
        context = component.private_context or {},
        access_level = component.access_level or 0,
        impl_id = component.impl_id,
        success = true
    }
end

return { handle = handle }