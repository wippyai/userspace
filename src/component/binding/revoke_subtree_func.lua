local sql = require("sql")
local security = require("security")
local errors = errors
local ops = require("ops")

-- Resolve the revoke subject: a user_id or a group_id (exactly one).
local function resolve_subject(subject)
    if type(subject) ~= "table" then
        return nil, "subject must be a table with user_id or group_id"
    end
    local user_id = subject.user_id
    local group_id = subject.group_id
    local has_user = type(user_id) == "string" and user_id ~= ""
    local has_group = type(group_id) == "string" and group_id ~= ""
    if has_user and has_group then
        return nil, "subject must contain exactly one of user_id or group_id"
    end
    if has_user then
        return user_id, nil
    end
    if has_group then
        return group_id, nil
    end
    return nil, "subject must contain a non-empty user_id or group_id"
end

local function handle(request_dto)
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = "Invalid request: must be a table", kind = errors.INVALID }
    end

    local root_id = request_dto.root_component_id
    if not root_id or type(root_id) ~= "string" or root_id == "" then
        return { success = false, error = "root_component_id is required and must be a non-empty string", kind = errors.INVALID }
    end

    local subject_id, subject_err = resolve_subject(request_dto.subject)
    if subject_err then
        return { success = false, error = subject_err, kind = errors.INVALID }
    end

    local actor = security.actor()
    if not actor then
        return { success = false, error = "No authenticated actor found", kind = errors.PERMISSION_DENIED }
    end
    local user_id = actor:id()
    if not user_id or user_id == "" then
        return { success = false, error = "Invalid actor ID", kind = errors.PERMISSION_DENIED }
    end

    local db, err_db = sql.get(ops.DB_RESOURCE)
    if err_db then
        return { success = false, error = "Failed to connect to database: " .. err_db, kind = errors.INTERNAL }
    end

    local tx, err_tx = db:begin()
    if err_tx then
        db:release()
        return { success = false, error = "Failed to begin transaction: " .. err_tx, kind = errors.INTERNAL }
    end

    -- ADMIN on the root authorizes revoking across the whole subtree.
    local has_access = ops.check_user_access(tx, user_id, root_id, ops.ACCESS.ADMIN)
    if not has_access then
        tx:rollback()
        db:release()
        return { success = false, error = "Insufficient access to revoke on this subtree (ADMIN required)", kind = errors.PERMISSION_DENIED }
    end

    local result, err = ops.apply_subtree_access(tx, db, root_id, subject_id, 0, true)
    if err then
        tx:rollback()
        db:release()
        local kind = errors.is(err :: any, errors.NOT_FOUND) and errors.NOT_FOUND or errors.INTERNAL
        return { success = false, error = tostring(err), kind = kind }
    end

    local commit_ok, err_commit = tx:commit()
    if err_commit then
        tx:rollback()
        db:release()
        return { success = false, error = "Failed to commit transaction: " .. err_commit, kind = errors.INTERNAL }
    end

    db:release()

    return {
        root_component_id = root_id,
        affected = result.affected,
        changes_made = result.changes_made,
        success = true
    }
end

return { handle = handle }
