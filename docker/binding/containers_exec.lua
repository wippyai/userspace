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
    command: string,
    env: {[string]: string}?,
    work_dir: string?,
    user: string?,
    timeout: string?,
})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end
    if not input.command or input.command == "" then
        return { success = false, error = "command is required" }
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
    if not container.docker_id or container.docker_id == "" then
        db:release()
        return { success = false, error = "container has no docker_id" }
    end
    if container.status ~= consts.status.RUNNING then
        db:release()
        return { success = false, error = "container is not running (status: " .. tostring(container.status) .. ")" }
    end

    db:release()

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = tostring(docker_err) }
    end

    local env_array: {string}? = nil
    if input.env then
        env_array = {}
        for k, v in pairs(input.env) do
            table.insert(env_array, k .. "=" .. v)
        end
    end

    local result, exec_err = docker:exec_container(tostring(container.docker_id), input.command, {
        env = env_array,
        work_dir = input.work_dir,
        user = input.user,
        timeout = input.timeout,
    })

    if exec_err then
        return { success = false, error = tostring(exec_err) }
    end

    return {
        success = true,
        stdout = result.stdout,
        stderr = result.stderr,
        exit_code = result.exit_code,
    }
end

return { handle = handle }
