local sql = require("sql")
local security = require("security")
local errors = errors
local ops = require("ops")

-- Surface a structured error through the contract's {success,error,kind} shape.
local function fail(message, kind)
    return { success = false, error = message, kind = kind }
end

local function handle(request_dto)
    if not request_dto or type(request_dto) ~= "table" then
        return fail("Invalid request: must be a table", errors.INVALID)
    end

    if not request_dto.component_id or type(request_dto.component_id) ~= "string" or request_dto.component_id == "" then
        return fail("component_id is required and must be a non-empty string", errors.INVALID)
    end

    -- parent_id is optional; an explicit nil/false moves the component to root.
    local has_parent_arg = request_dto.parent_id ~= nil
    local parent_id = request_dto.parent_id
    if parent_id ~= nil and parent_id ~= false and (type(parent_id) ~= "string" or parent_id == "") then
        return fail("parent_id must be a non-empty string, false, or null", errors.INVALID)
    end
    if parent_id == false then
        parent_id = nil
    end

    local position = request_dto.position
    if position ~= nil and (type(position) ~= "string" or position == "") then
        return fail("position must be a non-empty string if provided", errors.INVALID)
    end

    local actor = security.actor()
    if not actor then
        return fail("No authenticated actor found", errors.PERMISSION_DENIED)
    end
    local user_id = actor:id()
    if not user_id or user_id == "" then
        return fail("Invalid actor ID", errors.PERMISSION_DENIED)
    end

    local db, err_db = sql.get(ops.DB_RESOURCE)
    if err_db then
        return fail("Failed to connect to database: " .. err_db, errors.INTERNAL)
    end

    local tx, err_tx = db:begin()
    if err_tx then
        db:release()
        return fail("Failed to begin transaction: " .. err_tx, errors.INTERNAL)
    end

    -- WRITE access on the moved component.
    local has_access = ops.check_user_access(tx, user_id, request_dto.component_id, ops.ACCESS.WRITE)
    if not has_access then
        tx:rollback()
        db:release()
        return fail("Insufficient access to place this component", errors.PERMISSION_DENIED)
    end

    local result, err = ops.dispatch(tx, db, {
        type = ops.COMMAND_TYPES.SET_PLACEMENT,
        payload = {
            component_id = request_dto.component_id,
            has_parent_arg = has_parent_arg,
            parent_id = parent_id,
            position = position
        }
    })

    if err then
        tx:rollback()
        db:release()
        local kind = (errors.is(err :: any, errors.INVALID) and errors.INVALID)
            or (errors.is(err :: any, errors.NOT_FOUND) and errors.NOT_FOUND)
            or errors.INTERNAL
        return { success = false, error = tostring(err), kind = kind }
    end

    local commit_ok, err_commit = tx:commit()
    if err_commit then
        tx:rollback()
        db:release()
        return fail("Failed to commit transaction: " .. err_commit, errors.INTERNAL)
    end

    db:release()

    return {
        component_id = result.component_id,
        parent_id = result.parent_id,
        position = result.position,
        changes_made = result.changes_made,
        success = true
    }
end

return { handle = handle }
