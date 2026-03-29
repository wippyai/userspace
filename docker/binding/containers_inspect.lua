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

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local container = containers_repo.get(db, input.id)
    db:release()

    if not container then
        return { success = false, error = "container not found" }
    end

    local state: {[string]: any} = {
        status = container.status,
        docker_id = container.docker_id,
        exit_code = container.exit_code,
        error = container.error,
        group_id = container.group_id,
    }

    if not container.docker_id or container.docker_id == "" then
        return { success = true, state = state }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = true, state = state }
    end

    local info, inspect_err = docker:inspect_container(tostring(container.docker_id))
    if inspect_err then
        state.docker_error = tostring(inspect_err)
        return { success = true, state = state }
    end

    if info and info.State then
        state.running = info.State.Running
        if info.State.ExitCode ~= nil then
            state.exit_code = info.State.ExitCode
        end
        state.started_at = info.State.StartedAt
        state.finished_at = info.State.FinishedAt

        if info.State.Health then
            state.health = {
                status = info.State.Health.Status,
                failing_streak = info.State.Health.FailingStreak,
            }
        end
    end

    if info and info.NetworkSettings and info.NetworkSettings.Networks then
        local networks = {}
        for name, net in pairs(info.NetworkSettings.Networks) do
            networks[name] = {
                ip_address = net.IPAddress,
                gateway = net.Gateway,
                aliases = net.Aliases,
            }
        end
        state.networks = networks
    end

    return { success = true, state = state }
end

return { handle = handle }
