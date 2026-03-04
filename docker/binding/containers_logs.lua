local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: {id: string, stream: table?})
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

    local lines = containers_repo.get_logs(db, input.id)
    db:release()

    return { success = true, lines = lines }
end

return { handle = handle }
