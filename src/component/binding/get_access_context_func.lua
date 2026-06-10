local security = require("security")
local component_reader = require("component_reader")
local ops = require("ops")
local json = require("json")

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
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.component_id or type(request_dto.component_id) ~= "string" or request_dto.component_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    local actor = security.actor()
    if not actor then
        return { success = false, error = VALIDATION_ERRORS.NO_ACTOR }
    end

    local user_id = actor:id()
    if not user_id or user_id == "" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_ACTOR }
    end

    -- Query component with any access level (the access record itself grants
    -- execution context). Includes impl_id, private context, and access level.
    local reader = component_reader.new()
        :with_user(user_id)
        :with_components(request_dto.component_id)
        :include_options({
            meta = false,
            private_context = true,
            access_level = true
        })

    local component, read_err = reader:one()
    if read_err then
        return { success = false, error = tostring(read_err) }
    end
    if not component then
        return { success = false, error = BUSINESS_ERRORS.NOT_FOUND }
    end

    return {
        id = component.component_id,
        context = component.private_context or {},
        access_level = component.access_level or 0,
        impl_id = component.impl_id,
        success = true
    }
end

return { handle = handle }
