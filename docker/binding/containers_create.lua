local sql = require("sql")
local json = require("json")
local env = require("env")
local consts = require("consts")
local containers_repo = require("containers_repo")

local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

local function handle(input: {
    id: string?,
    image: string,
    command: string?,
    name: string?,
    env: {[string]: string}?,
    volumes: {host: string, container: string, mode: string?}[]?,
    ports: {host: number, container: number, protocol: string?}[]?,
    network: string?,
    work_dir: string?,
    user: string?,
    memory_limit: number?,
    cpu_quota: number?,
    labels: {[string]: string}?,
    group_id: string?,
    auto_remove: boolean?,
    interactive: boolean?,
    restart_policy: string?,
    max_restarts: number?,
    health_check: {test: {string}?, interval: number?, timeout: number?, retries: number?}?,
    extra_hosts: {string}?,
    cap_add: {string}?,
    dns: {string}?,
    group_add: {string}?,
    devices: {table}?,
    device_requests: {table}?,
    args: {string}?,
    entrypoint: {string}?,
    callback_pid: string?,
    callback_topic: string?,
    persist_logs: boolean?,
    created_by: string?,
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
        id = input.id,
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
        labels = input.labels,
        group_id = input.group_id,
        auto_remove = input.auto_remove,
        interactive = input.interactive,
        restart_policy = input.restart_policy,
        max_restarts = input.max_restarts,
        health_check = input.health_check,
        extra_hosts = input.extra_hosts,
        cap_add = input.cap_add,
        dns = input.dns,
        group_add = input.group_add,
        devices = input.devices,
        device_requests = input.device_requests,
        args = input.args,
        entrypoint = input.entrypoint,
        callback_pid = input.callback_pid,
        callback_topic = input.callback_topic,
        persist_logs = (input.persist_logs ~= nil and input.persist_logs or false) :: boolean,
        created_by = input.created_by,
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

    return { success = true, id = id, status = consts.status.PENDING }
end

return { handle = handle }
