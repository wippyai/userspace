local sql = require("sql")
local time = require("time")
local json = require("json")
local env = require("env")
local registry = require("registry")
local events = require("events")
local consts = require("consts")
local containers_repo = require("containers_repo")
local helpers = require("helpers")
local logger = require("logger")

-- Local name from a registry id ("ns.sub:entry" -> "entry"). Declarative
-- containers default to this so they get a stable Docker name (required for
-- reclaim) without a separate name field that would collide with the entry name.
local function short_name(id: string): string
    return id:match(":([^:]+)$") or id
end

local function create_from_entry(db, entry: {id: string, data: table?})
    local data = entry.data or {}
    local command = data.command and tostring(data.command) or nil
    local image = data.image and tostring(data.image) or "alpine:latest"
    local args = data.args :: {string}?
    -- A container entry needs something to run: a shell command, or raw args
    -- against the image entrypoint. Entries with neither are not containers.
    if not command and not args then
        return false
    end
    local existing = containers_repo.get(db, entry.id)
    if existing then
        local status = tostring(existing.status)
        -- A live or in-flight container is left alone; a stopped/failed one is
        -- recreated (the worker reclaims any leftover container before re-create).
        if status == consts.status.RUNNING or status == consts.status.PENDING or status == consts.status.CLAIMED then
            return false
        end
        containers_repo.delete(db, entry.id)
    end
    local _, create_err = containers_repo.create(db, {
        id = entry.id,
        image = image,
        command = command,
        args = args,
        entrypoint = data.entrypoint :: {string}?,
        name = (data.name and tostring(data.name)) or short_name(entry.id),
        interactive = (data.interactive or false) :: boolean,
        env = data.env :: {[string]: string}?,
        volumes = data.volumes :: {host: string, container: string, mode: string?}[]?,
        ports = data.ports :: {host: number, container: number, protocol: string?}[]?,
        network = data.network and tostring(data.network) or nil,
        work_dir = data.work_dir and tostring(data.work_dir) or nil,
        restart_policy = data.restart_policy and tostring(data.restart_policy) or nil,
        max_restarts = tonumber(data.max_restarts),
        labels = data.labels :: {[string]: string}?,
        persist_logs = false,
    })
    return not create_err
end

local function run()
    local log = logger:named("docker.root")

    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    if not db_id or db_id == "" then
        return nil, "database resource not configured: " .. consts.env.DATABASE_RESOURCE
    end

    local db, err = sql.get(db_id)
    if err then
        return nil, "failed to get database: " .. tostring(err)
    end

    local found_entries, find_err = registry.find({ ["meta.type"] = "docker.container" })
    if found_entries and #found_entries > 0 then
        local created = 0
        for _, entry in ipairs(found_entries) do
            if create_from_entry(db, entry) then
                created = created + 1
            end
        end
        if created > 0 then
            log:info("loaded containers from registry", { count = created })
        end
    end

    db:release()

    process.registry.register(consts.registry.ROOT)

    local host_id = env.get(consts.env.PROCESS_HOST)
    if not host_id or host_id == "" then
        return nil, "process host not configured: " .. consts.env.PROCESS_HOST
    end
    local worker_count = consts.defaults.WORKER_COUNT

    local worker_config = {
        db_id = db_id,
        socket_path = "/var/run/docker.sock",
        exec_images = {},
    }

    local monitor_config = {
        db_id = db_id,
        socket_path = "/var/run/docker.sock",
        monitor_interval = consts.defaults.MONITOR_INTERVAL,
        log_ttl = consts.defaults.LOG_TTL,
    }

    local builder_config = {
        db_id = db_id,
        socket_path = "/var/run/docker.sock",
    }

    local workers = {}
    local subscribers = {}       -- container_id -> {pid -> true}
    local build_subscribers = {} -- build_id -> {pid -> true}
    local proc_events = process.events()
    local inbox = process.inbox()

    local registry_sub, reg_err = events.subscribe("registry", "entry.create")
    if reg_err then
        log:warn("failed to subscribe to registry events", { error = tostring(reg_err) })
    end
    local registry_ch = registry_sub and registry_sub:channel() or nil

    for i = 1, worker_count do
        local pid, spawn_err = process.spawn_linked_monitored(
            "userspace.docker.service:worker", host_id, worker_config
        )
        if pid then
            workers[pid] = { index = i, started_at = os.time() }
        else
            log:warn("failed to spawn worker", { index = i, error = tostring(spawn_err) })
        end
    end

    local monitor_pid, monitor_err = process.spawn_linked_monitored(
        "userspace.docker.service:monitor", host_id, monitor_config
    )
    if monitor_err then
        log:warn("failed to spawn monitor", { error = tostring(monitor_err) })
    end

    local builder_pid, builder_err = process.spawn_linked_monitored(
        "userspace.docker.service:image_builder", host_id, builder_config
    )
    if builder_err then
        log:warn("failed to spawn image builder", { error = tostring(builder_err) })
    end

    log:info("started", { workers = worker_count })

    local select_cases = {
        proc_events:case_receive(),
        inbox:case_receive(),
    }
    if registry_ch then
        table.insert(select_cases, registry_ch:case_receive())
    end

    while true do
        local result = channel.select(select_cases)

        if result.channel == registry_ch then
            local evt = result.value
            if evt and evt.data and evt.data.meta and evt.data.meta.type == "docker.container" then
                local reg_db, reg_db_err = sql.get(db_id)
                if not reg_db_err then
                    if create_from_entry(reg_db, evt.data) then
                        log:info("container added from registry", { id = evt.data.id })
                        for pid, _ in pairs(workers) do
                            process.send(pid, consts.topic.CONTAINER_NEW, "")
                        end
                    end
                    reg_db:release()
                end
            end

        elseif result.channel == proc_events then
            local event = result.value
            if event.kind == process.event.CANCEL then
                break
            end
            if event.kind == process.event.EXIT and event.from then
                if workers[event.from] then
                    local w_index = workers[event.from].index
                    workers[event.from] = nil
                    time.sleep("2s")
                    local new_pid = process.spawn_linked_monitored(
                        "userspace.docker.service:worker", host_id, worker_config
                    )
                    if new_pid then
                        workers[new_pid] = { index = w_index, started_at = os.time() }
                    end
                elseif event.from == monitor_pid then
                    time.sleep("5s")
                    monitor_pid = process.spawn_linked_monitored(
                        "userspace.docker.service:monitor", host_id, monitor_config
                    )
                elseif event.from == builder_pid then
                    time.sleep("2s")
                    builder_pid = process.spawn_linked_monitored(
                        "userspace.docker.service:image_builder", host_id, builder_config
                    )
                end

                local exited_pid = tostring(event.from)
                for cid, subs in pairs(subscribers) do
                    if subs[exited_pid] then
                        subs[exited_pid] = nil
                    end
                end
                for bid, subs in pairs(build_subscribers) do
                    if subs[exited_pid] then
                        subs[exited_pid] = nil
                    end
                end
            end
        elseif result.channel == inbox then
            local msg = result.value
            local topic = msg:topic()

            if topic == consts.topic.CONTAINER_NEW then
                for pid, _ in pairs(workers) do
                    process.send(pid, consts.topic.CONTAINER_NEW, "")
                end

            elseif topic == consts.topic.SUBSCRIBE then
                local payload = helpers.extract_payload(msg)
                if payload and payload.container_id and payload.pid then
                    local cid = tostring(payload.container_id)
                    local sub_pid = tostring(payload.pid)
                    if not subscribers[cid] then
                        subscribers[cid] = {}
                    end
                    subscribers[cid][sub_pid] = true
                end

            elseif topic == consts.topic.UNSUBSCRIBE then
                local payload = helpers.extract_payload(msg)
                if payload and payload.container_id and payload.pid then
                    local cid = tostring(payload.container_id)
                    local sub_pid = tostring(payload.pid)
                    if subscribers[cid] then
                        subscribers[cid][sub_pid] = nil
                    end
                end

            elseif topic == consts.topic.CONTAINER_LOG then
                local payload = helpers.extract_payload(msg)
                if payload and payload.container_id then
                    local subs = subscribers[tostring(payload.container_id)]
                    if subs then
                        local event = {
                            type = "log",
                            container_id = payload.container_id,
                            line = payload.line,
                            stream = payload.stream,
                            timestamp = payload.timestamp or os.time(),
                        }
                        local encoded = json.encode(event)
                        for sub_pid, _ in pairs(subs) do
                            process.send(tostring(sub_pid), consts.topic.CONTAINER_LOG, encoded)
                        end
                    end
                end

            elseif topic == consts.topic.CONTAINER_STATUS then
                local payload = helpers.extract_payload(msg)
                if payload and payload.container_id then
                    local cid = tostring(payload.container_id)
                    local subs = subscribers[cid]
                    if subs then
                        local event = {
                            type = "status",
                            container_id = payload.container_id,
                            status = payload.status,
                            exit_code = payload.exit_code,
                        }
                        local encoded = json.encode(event)
                        for sub_pid, _ in pairs(subs) do
                            process.send(tostring(sub_pid), consts.topic.CONTAINER_STATUS, encoded)
                        end

                        -- send done event for terminal statuses
                        if payload.status == consts.status.STOPPED or payload.status == consts.status.FAILED or payload.status == consts.status.REMOVED then
                            local done_encoded = json.encode({ type = "done" })
                            for sub_pid, _ in pairs(subs) do
                                process.send(tostring(sub_pid), consts.topic.CONTAINER_STATUS, done_encoded)
                            end
                            subscribers[cid] = nil
                        end
                    end
                end

            elseif topic == consts.topic.STDIN then
                local payload = helpers.extract_payload(msg)
                local str = type(payload) == "string" and payload or json.encode(payload)
                for pid, _ in pairs(workers) do
                    process.send(pid, consts.topic.STDIN, str)
                end

            elseif topic == consts.topic.IMAGE_BUILD_NEW then
                if builder_pid then
                    local payload = helpers.extract_payload(msg)
                    local str = type(payload) == "string" and payload or json.encode(payload)
                    process.send(builder_pid, consts.topic.IMAGE_BUILD_NEW, str)
                end

            elseif topic == consts.topic.IMAGE_BUILD_SUBSCRIBE then
                local payload = helpers.extract_payload(msg)
                if payload and payload.build_id and payload.pid then
                    local bid = tostring(payload.build_id)
                    local sub_pid = tostring(payload.pid)
                    if not build_subscribers[bid] then
                        build_subscribers[bid] = {}
                    end
                    build_subscribers[bid][sub_pid] = true
                end

            elseif topic == consts.topic.IMAGE_BUILD_UNSUBSCRIBE then
                local payload = helpers.extract_payload(msg)
                if payload and payload.build_id and payload.pid then
                    local bid = tostring(payload.build_id)
                    local sub_pid = tostring(payload.pid)
                    if build_subscribers[bid] then
                        build_subscribers[bid][sub_pid] = nil
                    end
                end

            elseif topic == consts.topic.IMAGE_BUILD_LOG then
                local payload = helpers.extract_payload(msg)
                if payload and payload.build_id then
                    local subs = build_subscribers[tostring(payload.build_id)]
                    if subs then
                        local event = {
                            type = "build_log",
                            build_id = payload.build_id,
                            line = payload.line,
                        }
                        local encoded = json.encode(event)
                        for sub_pid, _ in pairs(subs) do
                            process.send(tostring(sub_pid), consts.topic.IMAGE_BUILD_LOG, encoded)
                        end
                    end
                end

            elseif topic == consts.topic.IMAGE_BUILD_STATUS then
                local payload = helpers.extract_payload(msg)
                if payload and payload.build_id then
                    local bid = tostring(payload.build_id)
                    local subs = build_subscribers[bid]
                    if subs then
                        local event = {
                            type = "build_status",
                            build_id = payload.build_id,
                            status = payload.status,
                            error = payload.error,
                        }
                        local encoded = json.encode(event)
                        for sub_pid, _ in pairs(subs) do
                            process.send(tostring(sub_pid), consts.topic.IMAGE_BUILD_STATUS, encoded)
                        end

                        if payload.status == consts.build_status.COMPLETED or payload.status == consts.build_status.FAILED then
                            local done_encoded = json.encode({ type = "done" })
                            for sub_pid, _ in pairs(subs) do
                                process.send(tostring(sub_pid), consts.topic.IMAGE_BUILD_STATUS, done_encoded)
                            end
                            build_subscribers[bid] = nil
                        end
                    end
                end
            end
        end
    end

    if registry_sub then
        registry_sub:close()
    end

    return { status = "shutdown" }
end

return { run = run }
