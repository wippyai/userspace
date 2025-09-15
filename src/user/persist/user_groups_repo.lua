local sql = require("sql")
local time = require("time")

local consts = require("consts")

local user_groups_repo = {}

local function get_db()
    local db_resource = consts.get_db_resource()
    local db, err = sql.get(db_resource)
    if err then
        return nil, consts.ERROR.DB_CONNECTION_FAILED .. ": " .. err
    end
    return db
end

function user_groups_repo.assign_user_to_group(user_id, group_id)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    if not group_id or group_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "group_id"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local user_check = sql.builder.select("user_id")
        :from("app_users")
        :where("user_id = ?", user_id)
        :limit(1)

    local user_executor = user_check:run_with(db)
    local users, err = user_executor:query()

    if err then
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    if #users == 0 then
        db:release()
        return nil, consts.ERROR.USER_NOT_FOUND
    end

    local check_query = sql.builder.select("user_id", "group_id")
        :from("app_user_groups")
        :where("user_id = ? AND group_id = ?", user_id, group_id)
        :limit(1)

    local check_executor = check_query:run_with(db)
    local existing, err = check_executor:query()

    if err then
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    if #existing > 0 then
        db:release()
        return {
            user_id = user_id,
            group_id = group_id,
            already_assigned = true
        }
    end

    local insert_query = sql.builder.insert("app_user_groups")
        :set_map({
            user_id = user_id,
            group_id = group_id,
            created_at = time.now():unix()
        })

    local insert_executor = insert_query:run_with(db)
    local result, err = insert_executor:exec()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        user_id = user_id,
        group_id = group_id,
        assigned = true
    }
end

function user_groups_repo.remove_user_from_group(user_id, group_id)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    if not group_id or group_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "group_id"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.delete("app_user_groups")
        :where("user_id = ? AND group_id = ?", user_id, group_id)

    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        user_id = user_id,
        group_id = group_id,
        removed = result.rows_affected > 0
    }
end

function user_groups_repo.get_user_groups(user_id)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("group_id", "created_at")
        :from("app_user_groups")
        :where("user_id = ?", user_id)
        :order_by("created_at ASC")

    local executor = query:run_with(db)
    local groups, err = executor:query()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    local group_ids = {}
    for _, group in ipairs(groups) do
        table.insert(group_ids, group.group_id)
    end

    return {
        user_id = user_id,
        groups = group_ids,
        details = groups
    }
end

function user_groups_repo.get_group_users(group_id)
    if not group_id or group_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "group_id"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("ug.user_id", "ug.created_at", "u.email", "u.full_name", "u.status")
        :from("app_user_groups ug")
        :join("app_users u ON ug.user_id = u.user_id")
        :where("ug.group_id = ?", group_id)
        :order_by("ug.created_at ASC")

    local executor = query:run_with(db)
    local users, err = executor:query()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        group_id = group_id,
        users = users
    }
end

function user_groups_repo.get_user_with_groups(identifier)
    if not identifier or identifier == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "identifier"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local user_query = sql.builder.select("user_id", "email", "full_name", "password_hash", "status", "created_at", "updated_at")
        :from("app_users")
        :where("user_id = ? OR email = ?", identifier, identifier)
        :limit(1)

    local user_executor = user_query:run_with(db)
    local users, err = user_executor:query()

    if err then
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    if #users == 0 then
        db:release()
        return nil, consts.ERROR.USER_NOT_FOUND
    end

    local user = users[1]

    local groups_query = sql.builder.select("group_id")
        :from("app_user_groups")
        :where("user_id = ?", user.user_id)
        :order_by("created_at ASC")

    local groups_executor = groups_query:run_with(db)
    local groups, err = groups_executor:query()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    local group_ids = {}
    for _, group in ipairs(groups) do
        table.insert(group_ids, group.group_id)
    end

    user.security_groups = group_ids

    return user
end

function user_groups_repo.remove_all_user_groups(user_id)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.delete("app_user_groups")
        :where("user_id = ?", user_id)

    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        user_id = user_id,
        groups_removed = result.rows_affected
    }
end

function user_groups_repo.set_user_groups(user_id, group_ids)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    if not group_ids or type(group_ids) ~= "table" then
        return nil, consts.ERROR.INVALID_FIELD_VALUE .. "group_ids must be an array"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local tx, err = db:begin()
    if err then
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    local delete_query = sql.builder.delete("app_user_groups")
        :where("user_id = ?", user_id)

    local delete_executor = delete_query:run_with(tx)
    local delete_result, err = delete_executor:exec()

    if err then
        tx:rollback()
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    local groups_added = 0
    local now = time.now():unix()

    for _, group_id in ipairs(group_ids) do
        if group_id and group_id ~= "" then
            local insert_query = sql.builder.insert("app_user_groups")
                :set_map({
                    user_id = user_id,
                    group_id = group_id,
                    created_at = now
                })

            local insert_executor = insert_query:run_with(tx)
            local result, err = insert_executor:exec()

            if err then
                tx:rollback()
                db:release()
                return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
            end

            groups_added = groups_added + 1
        end
    end

    local ok, err = tx:commit()
    if err then
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    db:release()

    return {
        user_id = user_id,
        groups_removed = delete_result.rows_affected,
        groups_added = groups_added,
        security_groups = group_ids
    }
end

return user_groups_repo