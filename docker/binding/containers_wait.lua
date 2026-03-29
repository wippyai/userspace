local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")
local consts = require("consts")

local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

local function handle(input: {
    id: string,
})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end

    -- Read container state
    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local container = containers_repo.get(db, input.id)
    db:release()

    if not container then
        return { success = false, error = "container not found" }
    end

    if container.status == consts.status.STOPPED or container.status == consts.status.FAILED or container.status == consts.status.REMOVED then
        return {
            success = true,
            status = container.status,
            exit_code = tonumber(container.exit_code) or -1,
        }
    end

    if not container.docker_id or container.docker_id == "" then
        return { success = false, error = "container has no docker_id" }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = tostring(docker_err) }
    end

    -- Blocking wait — no db held
    local result, wait_err = docker:wait_container(tostring(container.docker_id))
    if wait_err then
        return { success = false, error = tostring(wait_err) }
    end

    local exit_code = -1
    if result and result.StatusCode ~= nil then
        exit_code = tonumber(result.StatusCode) or -1
    end

    local final_status = exit_code == 0 and consts.status.STOPPED or consts.status.FAILED

    -- Reacquire db to persist status
    local db2, db2_err = get_db()
    if not db2_err then
        containers_repo.update_status(db2, input.id, final_status, {
            exit_code = exit_code,
            stopped_at = os.time(),
        })
        db2:release()
    end

    return {
        success = true,
        status = final_status,
        exit_code = exit_code,
    }
end

return { handle = handle }
