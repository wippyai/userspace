local provider_registry = require("provider_registry")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table or nil",
    INVALID_FILTERS = "filters must be a table",
    INVALID_GROUPS = "filters.groups must be an array of strings",
    INVALID_CLASSES = "filters.classes must be an array of strings"
}

local function validate_string_array(arr, field_name)
    if not arr then
        return nil -- Optional field
    end

    if type(arr) ~= "table" then
        return field_name .. " must be an array"
    end

    for i, item in ipairs(arr) do
        if type(item) ~= "string" or item == "" then
            return field_name .. "[" .. i .. "] must be a non-empty string"
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

    -- Validate filters
    local filters = request_dto.filters or {}
    if type(filters) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_FILTERS }
    end

    -- Validate groups filter
    local groups_error = validate_string_array(filters.groups, "filters.groups")
    if groups_error then
        return { success = false, error = groups_error }
    end

    -- Validate classes filter
    local classes_error = validate_string_array(filters.classes, "filters.classes")
    if classes_error then
        return { success = false, error = classes_error }
    end

    -- Scan available providers (returns schema and UI config, no implementation details)
    local result, err = provider_registry.scan_available_providers(filters)
    if not result then
        return { success = false, error = err or "Failed to scan providers" }
    end

    -- Success response - only public information, schema, and UI config
    return {
        providers = result.providers,
        total_count = result.total_count,
        available_groups = result.available_groups,
        available_classes = result.available_classes,
        success = true
    }
end

return { handle = handle }