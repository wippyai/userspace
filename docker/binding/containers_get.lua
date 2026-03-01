local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: {id: string})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local container = containers_repo.get(db, input.id)
    db:release()

    if not container then
        return { success = true, container = nil }
    end

    return { success = true, container = container }
end

return { handle = handle }
