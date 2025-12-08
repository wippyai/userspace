local sql = require("sql")
local consts = require("onboard_consts")
local time = require("time")

local onboard_db = {}

-- Helper function to get database connection
local function get_db()
    local db, err = sql.get(consts.APP_DB)
    if err or not db then
        return nil, "Failed to connect to database: " .. tostring(err)
    end
    return db
end

-- Save the onboarding flag for the user
function onboard_db.save_onboarding_flag(user_id, flag)
    if not user_id or user_id == "" then
        return false, "Missing user_id"
    end
    if not flag or flag == "" then
        return false, "Missing flag"
    end

    local now_ts = time.now():format(time.RFC3339NANO)
    local existing, err = onboard_db.get_onboarding_flag(user_id, flag)
    if err then
        return false, err or "Failed to check existing flag"
    end

    local db, err_db = get_db()
    if err_db then
        return false, err_db
    end
    local ok, exec_err
    if not existing then
        local insert_query = sql.builder.insert("onboarding")
            :set_map({
                user_id = user_id,
                flag = flag,
                completed_at = now_ts
            })
        local executor = insert_query:run_with(db)
        ok, exec_err = executor:exec()
    else
        local update_query = sql.builder.update("onboarding")
            :set("completed_at", now_ts)
            :where("user_id = ? AND flag = ?", user_id, flag)

        local executor = update_query:run_with(db)
        ok, exec_err = executor:exec()
    end

    db:release()
    if not ok then
        return false, exec_err or "Failed to execute query"
    end

    return true
end

function onboard_db.get_onboarding_flag(user_id, flag)
    if not user_id or user_id == "" then
        return nil, "Missing user_id"
    end
    if not flag or flag == "" then
        return nil, "Missing flag"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local select_query = sql.builder.select("user_id", "flag", "completed_at")
        :from("onboarding")
        :where("user_id = ? AND flag = ?", user_id, flag)
        :limit(1)

    local executor = select_query:run_with(db)
    local rows, err = executor:query()
    db:release()

    if err then
        return nil, err
    end

    return rows[1], nil
end

-- Get the onboarding flags for the user
function onboard_db.get_onboarding_flags(user_id)
    if not user_id or user_id == "" then
        return nil, "Missing user_id"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local select_query = sql.builder.select("user_id", "flag", "completed_at")
        :from("onboarding")
        :where("user_id = ?", user_id)

    local executor = select_query:run_with(db)
    local rows, err = executor:query()
    db:release()

    if err then
        return nil, err
    end

    if not rows then
        rows = {}
    end

    return rows, nil
end

-- Delete the onboarding flag for the user
function onboard_db.delete_onboarding_flag(user_id, flag)
    if not user_id or user_id == "" then
        return false, "Missing user_id"
    end
    if not flag or flag == "" then
        return false, "Missing flag"
    end

    local db, err_db = get_db()
    if err_db then
        return false, err_db
    end

    local delete_query = sql.builder.delete("onboarding")
        :where("user_id = ? AND flag = ?", user_id, flag)

    local executor = delete_query:run_with(db)
    local ok, exec_err = executor:exec()
    db:release()

    if not ok then
        return false, exec_err or "Failed to execute query"
    end

    return true
end

return onboard_db
