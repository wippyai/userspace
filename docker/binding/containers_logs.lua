local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")

local consts = require("consts")
local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

local function handle(input: {id: string, after_log_id: number?, cursor: number?, limit: number?, stream: string?})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local container = containers_repo.get(db, input.id)
    if not container then
        db:release()
        return { success = false, error = "container not found" }
    end

    local after_cursor = input.cursor
    if after_cursor == nil then after_cursor = input.after_log_id end
    local lines, logs_err, page = containers_repo.get_logs(db, input.id, {
        after_cursor = after_cursor,
        limit = input.limit,
        stream = input.stream,
    })
    db:release()

    if logs_err then return { success = false, error = tostring(logs_err) } end

    return {
        success = true,
        lines = lines,
        page = page,
        next_cursor = page and page.next_after_log_id or nil,
    }
end

return { handle = handle }
