local component_registry = require("component_registry")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table or nil",
    INVALID_FILTERS = "filters must be a table",
    INVALID_CLASSES = "filters.classes must be an array of strings",
    INVALID_NAMESPACES = "filters.namespaces must be an array of strings",
    INVALID_SEARCH = "filters.search must be a string",
    INVALID_INCLUDE_UI = "include_ui_bindings must be a boolean"
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

    -- Validate classes filter
    local classes_error = validate_string_array(filters.classes, "filters.classes")
    if classes_error then
        return { success = false, error = classes_error }
    end

    -- Validate namespaces filter
    local namespaces_error = validate_string_array(filters.namespaces, "filters.namespaces")
    if namespaces_error then
        return { success = false, error = namespaces_error }
    end

    -- Validate search filter
    if filters.search ~= nil and type(filters.search) ~= "string" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_SEARCH }
    end

    -- Validate include_ui_bindings
    local include_ui_bindings = request_dto.include_ui_bindings
    if include_ui_bindings ~= nil and type(include_ui_bindings) ~= "boolean" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_INCLUDE_UI }
    end

    -- Scan available components
    local result, err = component_registry.scan_available_components(filters, include_ui_bindings)
    if not result then
        return { success = false, error = err or "Failed to scan components" }
    end

    -- Success response
    return {
        components = result.components,
        total_count = result.total_count,
        available_classes = result.available_classes,
        success = true
    }
end

return { handle = handle }