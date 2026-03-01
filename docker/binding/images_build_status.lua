local sql = require("sql")
local env = require("env")
local images_repo = require("images_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: {build_id: string})
    if not input.build_id or input.build_id == "" then
        return { success = false, error = "build_id is required" }
    end

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local build = images_repo.get_build(db, input.build_id)
    db:release()

    if not build then
        return { success = true, build = nil }
    end

    return {
        success = true,
        build = {
            id = build.id,
            image_id = build.image_id,
            status = build.status,
            build_log = build.build_log,
            error = build.error,
            created_at = build.created_at,
            started_at = build.started_at,
            completed_at = build.completed_at,
        },
    }
end

return { handle = handle }
