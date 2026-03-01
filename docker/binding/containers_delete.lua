local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")

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
    if not container then
        db:release()
        return { success = false, error = "container not found" }
    end

    local warnings = {}

    if container.docker_id and container.docker_id ~= "" then
        local docker, docker_err = docker_client.new()
        if not docker then
            containers_repo.delete(db, input.id)
            db:release()
            return { success = false, error = "docker unavailable, record deleted but container may be orphaned: " .. tostring(docker_err) }
        end
        local _, stop_err = docker:stop_container(tostring(container.docker_id), 5)
        if stop_err then
            table.insert(warnings, "stop: " .. tostring(stop_err))
        end
        local _, rm_err = docker:remove_container(tostring(container.docker_id), true)
        if rm_err then
            table.insert(warnings, "remove: " .. tostring(rm_err))
        end
    end

    containers_repo.delete(db, input.id)
    db:release()

    local result: {[string]: any} = { success = true }
    if #warnings > 0 then
        result.warnings = warnings
    end

    return result
end

return { handle = handle }
