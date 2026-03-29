local docker_client = require("docker_client")
local json = require("json")
local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")
local consts = require("consts")

local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

local function handle(input: {id: string, timeout: number?})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end

    local db, db_err = get_db()
    if db_err then
        return { success = false, error = tostring(db_err) }
    end

    local container = containers_repo.get(db, input.id)
    if not container or not container.docker_id or container.docker_id == "" then
        db:release()
        return { success = false, error = "container not found or no docker_id" }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        db:release()
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local _, err = docker:restart_container(tostring(container.docker_id), input.timeout)
    if err then
        db:release()
        return { success = false, error = tostring(err) }
    end

    containers_repo.update_status(db, input.id, consts.status.RUNNING, {})
    db:release()

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if root_pid then
        process.send(root_pid, consts.topic.CONTAINER_STATUS, json.encode({
            container_id = input.id,
            status = consts.status.RUNNING,
        }))
    end

    return { success = true }
end

return { handle = handle }
