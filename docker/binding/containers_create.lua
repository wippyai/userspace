local sql = require("sql")
local json = require("json")
local env = require("env")
local consts = require("consts")
local containers_repo = require("containers_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

type ContainerInput = {
    image: string,
    command: string?,
    name: string?,
    env: {[string]: string}?,
    volumes: table?,
    ports: {host: number, container: number, protocol: string?}[]?,
    network: string?,
    work_dir: string?,
    user: string?,
    memory_limit: number?,
    cpu_quota: number?,
    auto_remove: boolean?,
    interactive: boolean?,
    persist_logs: boolean?,
    stream: table?,
}

local function handle(input)
    local data, verr = ContainerInput:is(input)
    if not data then
        return { success = false, error = "invalid input" }
    end

    if not data.image or data.image == "" then
        return { success = false, error = "image is required" }
    end

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local id, create_err = containers_repo.create(db, {
        image = data.image,
        command = data.command,
        name = data.name,
        env = data.env,
        volumes = data.volumes,
        ports = data.ports,
        network = data.network,
        work_dir = data.work_dir,
        user = data.user,
        memory_limit = data.memory_limit,
        cpu_quota = data.cpu_quota,
        auto_remove = data.auto_remove,
        interactive = data.interactive,
        persist_logs = data.persist_logs ~= nil and data.persist_logs or false,
    })

    db:release()

    if create_err then
        return { success = false, error = tostring(create_err) }
    end

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if root_pid then
        process.send(root_pid, consts.topic.CONTAINER_NEW, "")

        if data.stream and data.stream.reply_to then
            process.send(root_pid, consts.topic.SUBSCRIBE, json.encode({
                container_id = id,
                pid = tostring(data.stream.reply_to),
            }))
        end
    end

    return { success = true, id = id, status = "pending" }
end

return { handle = handle }
