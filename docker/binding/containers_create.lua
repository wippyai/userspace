local sql = require("sql")
local json = require("json")
local env = require("env")
local consts = require("consts")
local containers_repo = require("containers_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: {
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
    persist_logs: boolean?,
    stream: table?,
})
    if not input.image or input.image == "" then
        return { success = false, error = "image is required" }
    end

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local id, create_err = containers_repo.create(db, {
        image = input.image,
        command = input.command,
        name = input.name,
        env = input.env,
        volumes = input.volumes,
        ports = input.ports,
        network = input.network,
        work_dir = input.work_dir,
        user = input.user,
        memory_limit = input.memory_limit,
        cpu_quota = input.cpu_quota,
        auto_remove = input.auto_remove,
        interactive = input.interactive,
        persist_logs = input.persist_logs ~= nil and input.persist_logs or false,
    })

    db:release()

    if create_err then
        return { success = false, error = tostring(create_err) }
    end

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if root_pid then
        process.send(root_pid, consts.topic.CONTAINER_NEW, "")

        if input.stream and input.stream.reply_to then
            process.send(root_pid, consts.topic.SUBSCRIBE, json.encode({
                container_id = id,
                pid = tostring(input.stream.reply_to),
            }))
        end
    end

    return { success = true, id = id, status = "pending" }
end

return { handle = handle }
