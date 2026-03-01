local sql = require("sql")
local json = require("json")
local uuid = require("uuid")
local env = require("env")
local consts = require("consts")
local containers_repo = require("containers_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: {
    name: string?,
    network: string?,
    containers: table,
    stream: table?,
})
    local defs = input.containers
    if type(defs) ~= "table" or #defs == 0 then
        return { success = false, error = "containers array is required" }
    end

    local group_name = tostring(input.name or "compose")
    local group_id = group_name .. "-" .. uuid.v4():sub(1, 8)

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local results = {}
    for _, def in ipairs(defs) do
        local command = tostring(def.command or "")
        if command == "" then
            db:release()
            return { success = false, error = "each container requires a command" }
        end

        local image = tostring(def.image or "alpine:latest")
        local raw_name = def.name and tostring(def.name) or nil
        local name = raw_name and (group_id .. "-" .. raw_name) or nil

        local network = def.network and tostring(def.network) or input.network
        local id, create_err = containers_repo.create(db, {
            image = image,
            command = command,
            name = name,
            interactive = def.interactive or false,
            env = def.env :: {[string]: string}?,
            volumes = def.volumes :: table?,
            ports = def.ports :: {host: number, container: number, protocol: string?}[]?,
            network = network,
            work_dir = def.work_dir and tostring(def.work_dir) or nil,
            labels = { group = group_id },
            persist_logs = false,
        })

        if create_err then
            db:release()
            return { success = false, error = tostring(create_err) }
        end

        table.insert(results, { id = id, name = raw_name, status = "pending" })
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

    return { success = true, group = group_id, containers = results }
end

return { handle = handle }
