local security = require("security")
local component_reader = require("component_reader")
local ops = require("ops")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_COMPONENT_ID = "component_id is required and must be a non-empty string",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID"
}

local BUSINESS_ERRORS = {
    NOT_FOUND = "Component not found or access denied"
}

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.component_id or type(request_dto.component_id) ~= "string" or request_dto.component_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
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

    -- Query component with READ access requirement
    local reader = component_reader.new()
        :with_user(user_id)
        :with_components(request_dto.component_id)
        :with_access_mask(ops.ACCESS.READ)
        :include_options({
            meta = true,
            private_context = false  -- Never expose private context in get_component
        })

    local component = reader:one()

    if not component then
        return { success = false, error = BUSINESS_ERRORS.NOT_FOUND }
    end

    -- Success response with component data
    return {
        component_id = component.component_id,
        impl_id = component.impl_id,
        meta = component.meta or {},
        created_at = component.created_at,
        updated_at = component.updated_at,
        success = true
    }
end

return { handle = handle }