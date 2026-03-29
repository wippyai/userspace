local sql = require("sql")
local json = require("json")
local env = require("env")
local consts = require("consts")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")

local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

local function handle(input: {
    group: string,
    remove_network: boolean?,
})
    if not input.group or input.group == "" then
        return { success = false, error = "group is required" }
    end

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local containers = containers_repo.list_by_group(db, input.group)
    if not containers or #containers == 0 then
        db:release()
        return { success = true, containers_removed = 0, network_removed = false }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        db:release()
        return { success = false, error = "docker client: " .. tostring(docker_err) }
    end

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    local removed = 0

    for _, c in ipairs(containers) do
        local cid = tostring(c.id)

        if c.docker_id and c.docker_id ~= "" then
            docker:stop_container(tostring(c.docker_id), 5)
            docker:remove_container(tostring(c.docker_id), true)
        end

        containers_repo.delete(db, cid)
        removed = removed + 1

        if root_pid then
            process.send(root_pid, consts.topic.CONTAINER_STATUS, json.encode({
                container_id = cid,
                status = consts.status.REMOVED,
            }))
        end
    end

    db:release()

    local network_removed = false
    if input.remove_network ~= false then
        local _, net_err = docker:remove_network(input.group)
        if not net_err then
            network_removed = true
        end
    end

    return {
        success = true,
        containers_removed = removed,
        network_removed = network_removed,
    }
end

return { handle = handle }
