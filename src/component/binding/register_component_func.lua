local sql = require("sql")
local json = require("json")
local uuid = require("uuid")
local time = require("time")
local security = require("security")
local ops = require("ops")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_IMPL_ID = "impl_id is required and must be a non-empty string",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID",
    INVALID_PRIVATE_CONTEXT = "private_context must be a table",
    INVALID_META = "meta must be a table",
    INVALID_ADDITIONAL_ACCESS = "additional_access must be a table",
    INVALID_COMPONENT_ID = "component_id must be a non-empty string if provided",
    INVALID_PARENT_ID = "parent_id must be a non-empty string if provided",
    INVALID_POSITION = "position must be a non-empty string if provided"
}

local DATABASE_ERRORS = {
    CONNECTION_FAILED = "Failed to connect to database",
    TRANSACTION_FAILED = "Failed to begin transaction",
    CREATE_FAILED = "Failed to create component",
    ACCESS_FAILED = "Failed to grant additional access",
    COMMIT_FAILED = "Failed to commit transaction"
}

local function validate_additional_access(additional_access)
    for i, access_rule in ipairs(additional_access) do
        if type(access_rule) ~= "table" then
            return "additional_access[" .. i .. "] must be a table"
        end
        if not access_rule.user_id or type(access_rule.user_id) ~= "string" or access_rule.user_id == "" then
            return "additional_access[" .. i .. "].user_id is required"
        end
        if not access_rule.access_mask or type(access_rule.access_mask) ~= "number" or access_rule.access_mask < 0 then
            return "additional_access[" .. i .. "].access_mask must be a non-negative number"
        end
    end
    return nil
end

local function handle(request_dto)
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.impl_id or type(request_dto.impl_id) ~= "string" or request_dto.impl_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_IMPL_ID }
    end

    local actor = security.actor()
    if not actor then
        return { success = false, error = VALIDATION_ERRORS.NO_ACTOR }
    end

    local user_id = actor:id()
    if not user_id or user_id == "" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_ACTOR }
    end

    local private_context = request_dto.private_context or {}
    if type(private_context) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_PRIVATE_CONTEXT }
    end

    local meta = request_dto.meta or {}
    if type(meta) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_META }
    end

    local additional_access = request_dto.additional_access or {}
    if type(additional_access) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_ADDITIONAL_ACCESS }
    end

    local access_error = validate_additional_access(additional_access)
    if access_error then
        return { success = false, error = access_error }
    end

    local component_id = request_dto.component_id
    if component_id and (type(component_id) ~= "string" or component_id == "") then
        return { success = false, error = VALIDATION_ERRORS.INVALID_COMPONENT_ID }
    end
    if not component_id then
        component_id = uuid.v7()
    end

    -- Placement args: omitted => root + end-of-siblings (handled by ops).
    local parent_id = request_dto.parent_id
    if parent_id ~= nil and (type(parent_id) ~= "string" or parent_id == "") then
        return { success = false, error = VALIDATION_ERRORS.INVALID_PARENT_ID }
    end

    local position = request_dto.position
    if position ~= nil and (type(position) ~= "string" or position == "") then
        return { success = false, error = VALIDATION_ERRORS.INVALID_POSITION }
    end

    local db, err_db = sql.get(ops.DB_RESOURCE)
    if err_db then
        return { success = false, error = DATABASE_ERRORS.CONNECTION_FAILED .. ": " .. err_db }
    end

    local tx, err_tx = db:begin()
    if err_tx then
        db:release()
        return { success = false, error = DATABASE_ERRORS.TRANSACTION_FAILED .. ": " .. err_tx }
    end

    local create_command = {
        type = ops.COMMAND_TYPES.CREATE_COMPONENT,
        payload = {
            component_id = component_id,
            impl_id = request_dto.impl_id,
            private_context = private_context,
            initial_meta = meta,
            owner_user_id = user_id,
            parent_id = parent_id,
            position = position
        }
    }

    local create_result, err_create = ops.dispatch(tx, db, create_command)
    if err_create then
        tx:rollback()
        db:release()
        return { success = false, error = DATABASE_ERRORS.CREATE_FAILED .. ": " .. tostring(err_create) }
    end

    for _, access_rule in ipairs(additional_access) do
        local access_command = {
            type = ops.COMMAND_TYPES.GRANT_ACCESS,
            payload = {
                component_id = component_id,
                user_id = access_rule.user_id,
                access_mask = access_rule.access_mask
            }
        }

        local access_result, err_access = ops.dispatch(tx, db, access_command)
        if err_access then
            tx:rollback()
            db:release()
            return { success = false, error = DATABASE_ERRORS.ACCESS_FAILED .. ": " .. tostring(err_access) }
        end
    end

    local commit_ok, err_commit = tx:commit()
    if err_commit then
        tx:rollback()
        db:release()
        return { success = false, error = DATABASE_ERRORS.COMMIT_FAILED .. ": " .. err_commit }
    end

    db:release()

    return {
        component_id = component_id,
        impl_id = request_dto.impl_id,
        parent_id = parent_id,
        created_at = time.now():format(time.RFC3339),
        success = true
    }
end

return { handle = handle }
