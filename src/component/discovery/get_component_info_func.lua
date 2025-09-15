local component_registry = require("component_registry")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_COMPONENT_ID = "component_id is required and must be a non-empty string"
}

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.component_id or
       type(request_dto.component_id) ~= "string" or
       request_dto.component_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    -- Get component information
    local component_info, err = component_registry.get_component_info(request_dto.component_id)
    if not component_info then
        return { success = false, error = err or "Component not found" }
    end

    -- Success response
    local result = {
        id = component_info.id,
        name = component_info.name,
        description = component_info.description,
        classes = component_info.classes,
        namespace = component_info.namespace,
        methods = component_info.methods,
        success = true
    }

    if component_info.icon then
        result.icon = component_info.icon
    end

    if component_info.create_ui_id then
        result.create_ui_id = component_info.create_ui_id
    end

    if component_info.manage_ui_id then
        result.manage_ui_id = component_info.manage_ui_id
    end

    return result
end

return { handle = handle }