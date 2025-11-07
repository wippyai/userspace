local sql = require("sql")
local hash = require("hash")
local crypto = require("crypto")
local time = require("time")

local consts = require("consts")

local user_repo = {}

local function get_db()
    local db_resource = consts.get_db_resource()
    local db, err = sql.get(db_resource)
    if err then
        return nil, consts.ERROR.DB_CONNECTION_FAILED .. ": " .. err
    end
    return db
end

local function hash_password(password)
    local hashed, err = hash.sha512(password)
    if err then
        return nil, "Failed to hash password: " .. err
    end
    return hashed
end

function user_repo.create(user_data)
    if not user_data.user_id or user_data.user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    if not user_data.email or user_data.email == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "email"
    end

    if not user_data.password or user_data.password == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "password"
    end

    local email_valid, email_err = consts.validate_email(user_data.email)
    if not email_valid then
        return nil, email_err
    end

    local pass_valid, pass_err = consts.validate_password(user_data.password)
    if not pass_valid then
        return nil, pass_err
    end

    if user_data.status then
        local status_valid, status_err = consts.validate_user_status(user_data.status)
        if not status_valid then
            return nil, status_err
        end
    end

    local password_hash, err = hash_password(user_data.password)
    if err then
        return nil, err
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local check_query = sql.builder.select("user_id")
        :from("app_users")
        :where("user_id = ? OR email = ?", user_data.user_id, user_data.email)

    local check_executor = check_query:run_with(db)
    local existing_users, err = check_executor:query()

    if err then
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    if #existing_users > 0 then
        db:release()
        return nil, consts.ERROR.USER_ALREADY_EXISTS
    end

    local now = time.now()

    local insert_query = sql.builder.insert("app_users")
        :set_map({
            user_id = user_data.user_id,
            email = user_data.email,
            full_name = user_data.full_name or nil,
            password_hash = password_hash,
            status = user_data.status or consts.DEFAULTS.USER_STATUS,
            created_at = db:type() == sql.type.SQLITE and now:unix() or now:format(time.RFC3339),
            updated_at = db:type() == sql.type.SQLITE and now:unix() or now:format(time.RFC3339)
        })

    local insert_executor = insert_query:run_with(db)
    local result, err = insert_executor:exec()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        user_id = user_data.user_id,
        email = user_data.email,
        full_name = user_data.full_name,
        status = user_data.status or consts.DEFAULTS.USER_STATUS,
        created = true
    }
end

function user_repo.get(identifier)
    if not identifier or identifier == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "identifier"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("user_id", "email", "full_name", "password_hash", "status", "created_at", "updated_at")
        :from("app_users")
        :where("user_id = ? OR email = ?", identifier, identifier)
        :limit(1)

    local executor = query:run_with(db)
    local users, err = executor:query()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    if #users == 0 then
        return nil, consts.ERROR.USER_NOT_FOUND
    end

    return users[1]
end

function user_repo.verify_password(identifier, password)
    local user, err = user_repo.get(identifier)
    if err then
        return false, err
    end

    local password_hash, err = hash_password(password)
    if err then
        return false, err
    end

    local is_valid = crypto.constant_time_compare(user.password_hash, password_hash)
    if not is_valid then
        return false, consts.ERROR.INVALID_PASSWORD
    end

    return true, user
end

function user_repo.list(options)
    options = options or {}
    local limit = options.limit or 50
    local offset = options.offset or 0

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("user_id", "email", "full_name", "status", "created_at", "updated_at")
        :from("app_users")
        :order_by("created_at DESC")
        :limit(limit)
        :offset(offset)

    if options.status then
        query = query:where("status = ?", options.status)
    end

    local executor = query:run_with(db)
    local users, err = executor:query()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return users
end

function user_repo.update(user_id, update_data)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    if not update_data or next(update_data) == nil then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "update_data"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.update("app_users")
        :where("user_id = ?", user_id)

    if update_data.email then
        local email_valid, email_err = consts.validate_email(update_data.email)
        if not email_valid then
            db:release()
            return nil, email_err
        end
        query = query:set("email", update_data.email)
    end

    if update_data.full_name then
        query = query:set("full_name", update_data.full_name)
    end

    if update_data.password then
        local pass_valid, pass_err = consts.validate_password(update_data.password)
        if not pass_valid then
            db:release()
            return nil, pass_err
        end

        local password_hash, err = hash_password(update_data.password)
        if err then
            db:release()
            return nil, err
        end
        query = query:set("password_hash", password_hash)
    end

    if update_data.status then
        local status_valid, status_err = consts.validate_user_status(update_data.status)
        if not status_valid then
            db:release()
            return nil, status_err
        end
        query = query:set("status", update_data.status)
    end

    query = query:set(
        "updated_at",
        db:type() == sql.type.SQLITE and time.now():unix() or time.now():format(time.RFC3339)
    )

    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    if result.rows_affected == 0 then
        return nil, consts.ERROR.USER_NOT_FOUND
    end

    return {
        user_id = user_id,
        updated = true,
        rows_affected = result.rows_affected
    }
end

function user_repo.delete(user_id)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.delete("app_users")
        :where("user_id = ?", user_id)

    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    if result.rows_affected == 0 then
        return nil, consts.ERROR.USER_NOT_FOUND
    end

    return {
        user_id = user_id,
        deleted = true
    }
end

function user_repo.count(options)
    options = options or {}

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("COUNT(*) as count")
        :from("app_users")

    if options.status then
        query = query:where("status = ?", options.status)
    end

    local executor = query:run_with(db)
    local result, err = executor:query()

    db:release()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return result[1].count
end

return user_repo
