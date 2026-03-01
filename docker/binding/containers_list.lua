local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: {status: string?, limit: number?}?)
    local params = input or {}

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local filter: {status: string?, status_not: string?, limit: number?} = {
        limit = params.limit or 100,
    }

    if params.status and params.status ~= "" then
        filter.status = params.status
    else
        filter.status_not = "removed"
    end

    local rows = containers_repo.list(db, filter)
    db:release()

    return { success = true, containers = rows }
end

return { handle = handle }
