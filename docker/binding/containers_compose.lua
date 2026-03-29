local sql = require("sql")
local json = require("json")
local uuid = require("uuid")
local env = require("env")
local consts = require("consts")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")

local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

local function handle(input: {
    name: string?,
    network: string?,
    containers: table,
    labels: {[string]: string}?,
    stream: table?,
})
    local defs = input.containers
    if type(defs) ~= "table" or #defs == 0 then
        return { success = false, error = "containers array is required" }
    end

    local group_name = tostring(input.name or "compose")
    local group_id = group_name .. "-" .. uuid.v4():sub(1, 8)

    local network = input.network
    local auto_network = false
    local docker: any = nil

    if not network or network == "" then
        local d, docker_err = docker_client.new()
        if docker_err then
            return { success = false, error = "docker client: " .. tostring(docker_err) }
        end
        docker = d

        local _net, net_err = docker:create_network(group_id, "bridge")
        if net_err then
            return { success = false, error = "create network: " .. tostring(net_err) }
        end

        network = group_id
        auto_network = true
    end

    local db, err = get_db()
    if err then
        if auto_network and docker then
            docker:remove_network(group_id)
        end
        return { success = false, error = tostring(err) }
    end

    local results = {}
    local created_ids: {string} = {}

    for _, def in ipairs(defs) do
        local image = tostring(def.image or "alpine:latest")
        local raw_name = def.name and tostring(def.name) or nil
        local container_name = raw_name and (group_id .. "-" .. raw_name) or nil

        local labels: {[string]: string}? = nil
        if input.labels or def.labels then
            labels = {}
            if input.labels then
                for k, v in pairs(input.labels) do labels[k] = v end
            end
            if def.labels then
                for k, v in pairs(def.labels) do labels[k] = v end
            end
        end

        local id, create_err = containers_repo.create(db, {
            image = image,
            command = def.command and tostring(def.command) or nil,
            name = container_name,
            interactive = (def.interactive or false) :: boolean,
            env = def.env :: {[string]: string}?,
            volumes = def.volumes :: {host: string, container: string, mode: string?}[]?,
            ports = def.ports :: {host: number, container: number, protocol: string?}[]?,
            network = network,
            work_dir = def.work_dir and tostring(def.work_dir) or nil,
            user = def.user and tostring(def.user) or nil,
            memory_limit = def.memory_limit and tonumber(def.memory_limit) or nil,
            cpu_quota = def.cpu_quota and tonumber(def.cpu_quota) or nil,
            health_check = def.health_check :: {test: {string}?, interval: number?, timeout: number?, retries: number?}?,
            group_id = group_id,
            labels = labels,
            persist_logs = (def.persist_logs or false) :: boolean,
        })

        if create_err then
            for _, cid in ipairs(created_ids) do
                containers_repo.delete(db, cid)
            end
            db:release()
            if auto_network and docker then
                docker:remove_network(group_id)
            end
            return { success = false, error = tostring(create_err) }
        end

        if id then
            table.insert(created_ids, tostring(id))
            table.insert(results, { id = tostring(id), name = raw_name, status = consts.status.PENDING })
        end
    end

    db:release()

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if root_pid then
        process.send(root_pid, consts.topic.CONTAINER_NEW, "")

        if input.stream and input.stream.reply_to then
            for _, r in ipairs(results) do
                process.send(root_pid, consts.topic.SUBSCRIBE, json.encode({
                    container_id = r.id,
                    pid = tostring(input.stream.reply_to),
                }))
            end
        end
    end

    return {
        success = true,
        group = group_id,
        network = network,
        auto_network = auto_network,
        containers = results,
    }
end

return { handle = handle }
