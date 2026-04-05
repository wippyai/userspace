local sql = require("sql")
local exec = require("exec")
local time = require("time")
local json = require("json")
local consts = require("consts")
local spec = require("spec")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")
local helpers = require("helpers")

local logger = require("logger")

local function notify_root(root_pid, topic, payload)
    if root_pid then
        helpers.send_json(root_pid, topic, payload)
    end
end

local function notify_log(db_id, root_pid, cid, stream, line)
    local db = sql.get(db_id)
    if db then
        containers_repo.append_log(db, cid, stream, line)
        db:release()
    end
    notify_root(root_pid, consts.topic.CONTAINER_LOG, {
        container_id = cid,
        stream = stream,
        line = line,
    })
end

local function notify_status(root_pid, cid, status, extra)
    local payload = { container_id = cid, status = status }
    if extra then
        for k, v in pairs(extra) do payload[k] = v end
    end
    notify_root(root_pid, consts.topic.CONTAINER_STATUS, payload)
end

local function run_interactive(executor, db_id, c, active, root_pid)
    local cid: string = tostring(c.id)

    local db, db_err = sql.get(db_id)
    if db_err then
        notify_status(root_pid, cid, consts.status.FAILED, { error = "db unavailable" })
        if active then active[cid] = nil end
        return
    end

    local proc, proc_err = executor:exec(tostring(c.command))
    if proc_err then
        containers_repo.update_status(db, cid, consts.status.FAILED, {
            error = tostring(proc_err),
            stopped_at = os.time(),
        })
        db:release()
        notify_status(root_pid, cid, consts.status.FAILED, { error = tostring(proc_err) })
        if active then active[cid] = nil end
        return
    end

    local ok, start_err = proc:start()
    if start_err then
        containers_repo.update_status(db, cid, consts.status.FAILED, {
            error = tostring(start_err),
            stopped_at = os.time(),
        })
        db:release()
        notify_status(root_pid, cid, consts.status.FAILED, { error = tostring(start_err) })
        if active then active[cid] = nil end
        return
    end

    if active then
        active[cid] = { proc = proc }
    end

    -- Release DB before blocking IO — log writes use their own connections
    db:release()

    local function stream_lines(reader_fn, stream_name)
        local reader = reader_fn()
        if not reader then return end
        local remainder = ""
        while true do
            local chunk = reader:read()
            if not chunk then break end
            local text = remainder .. chunk
            remainder = ""
            local lines = {}
            local pos = 1
            while pos <= #text do
                local nl = text:find("\n", pos, true)
                if nl then
                    table.insert(lines, text:sub(pos, nl - 1))
                    pos = nl + 1
                else
                    remainder = text:sub(pos)
                    break
                end
            end
            if #lines > 0 then
                local chunk_db = sql.get(db_id)
                for _, line in ipairs(lines) do
                    local text = tostring(line)
                    if chunk_db then
                        containers_repo.append_log(chunk_db, cid, stream_name, text)
                    end
                    notify_root(root_pid, consts.topic.CONTAINER_LOG, {
                        container_id = cid,
                        stream = stream_name,
                        line = text,
                    })
                end
                if chunk_db then chunk_db:release() end
            end
        end
        if remainder ~= "" then
            notify_log(db_id, root_pid, cid, stream_name, remainder)
        end
        reader:close()
    end

    coroutine.spawn(function()
        stream_lines(function() return proc:stderr_stream() end, "stderr")
    end)

    stream_lines(function() return proc:stdout_stream() end, "stdout")

    local exit_code, wait_err = proc:wait()
    local final_status = consts.status.STOPPED
    if wait_err and not exit_code then
        final_status = consts.status.FAILED
    elseif exit_code and exit_code ~= 0 then
        final_status = consts.status.FAILED
    end

    local final_exit: number = tonumber(exit_code) or -1

    local final_db = sql.get(db_id)
    if final_db then
        containers_repo.update_status(final_db, cid, final_status, {
            exit_code = final_exit,
            error = wait_err and tostring(wait_err) or nil,
            stopped_at = os.time(),
        })
        final_db:release()
    end

    notify_status(root_pid, cid, final_status, { exit_code = final_exit })
end

local function run_managed(docker, db_id, c, root_pid)
    local cid: string = tostring(c.id)

    local db, db_err = sql.get(db_id)
    if db_err then
        notify_status(root_pid, cid, consts.status.FAILED, { error = "db unavailable" })
        return
    end

    local cfg = c.config or c
    local container_config = spec.build_container_config({
        image = tostring(cfg.image or c.image),
        command = cfg.command and tostring(cfg.command) or nil,
        env = cfg.env :: {[string]: string}?,
        volumes = cfg.volumes :: {host: string, container: string, mode: string?}[]?,
        ports = cfg.ports :: {host: number, container: number, protocol: string?}[]?,
        network = cfg.network and tostring(cfg.network) or nil,
        hostname = cfg.hostname and tostring(cfg.hostname) or nil,
        work_dir = cfg.work_dir and tostring(cfg.work_dir) or nil,
        user = cfg.user and tostring(cfg.user) or nil,
        memory_limit = tonumber(cfg.memory_limit),
        cpu_quota = tonumber(cfg.cpu_quota),
        interactive = cfg.interactive and true or false,
        labels = type(c.labels) == "table" and (c.labels :: {[string]: string}) or nil,
        extra_hosts = cfg.extra_hosts :: {string}?,
        restart_policy = cfg.restart_policy and {
            name = tostring(cfg.restart_policy),
            max_retry = tonumber(cfg.max_restarts),
        } or nil,
        healthcheck = cfg.health_check :: {test: {string}, interval: number?, timeout: number?, retries: number?, start_period: number?}?,
        cap_add = cfg.cap_add :: {string}?,
        dns = cfg.dns :: {string}?,
    })

    local create_params = {}
    if c.name then
        create_params.name = c.name
    end

    local created, create_err = docker:create_container(container_config, create_params)
    if create_err then
        containers_repo.update_status(db, cid, consts.status.FAILED, {
            error = "create: " .. tostring(create_err),
            stopped_at = os.time(),
        })
        db:release()
        notify_status(root_pid, cid, consts.status.FAILED, { error = "create: " .. tostring(create_err) })
        return
    end

    local docker_id: string = tostring(created.Id)
    containers_repo.update_status(db, cid, consts.status.RUNNING, {
        docker_id = docker_id,
        started_at = os.time(),
    })
    notify_status(root_pid, cid, consts.status.RUNNING, { docker_id = docker_id })

    local _, start_err = docker:start_container(docker_id)
    if start_err then
        containers_repo.update_status(db, cid, consts.status.FAILED, {
            error = "start: " .. tostring(start_err),
            stopped_at = os.time(),
        })
        db:release()
        notify_status(root_pid, cid, consts.status.FAILED, { error = "start: " .. tostring(start_err) })
        docker:remove_container(docker_id, true)
        return
    end

    -- Release DB before blocking poll loop — reacquire after
    db:release()

    local log_since = os.time() - 1
    local lines_seen = 0
    local exit_code: number = -1
    local final_status = consts.status.STOPPED
    local error_msg: string? = nil
    local max_polls = 3600

    for poll = 1, max_polls do
        local info, inspect_err = docker:inspect_container(docker_id)
        if inspect_err then
            final_status = consts.status.FAILED
            error_msg = "inspect failed: " .. tostring(inspect_err)
            break
        end

        local stopped = false
        if info and info.State then
            if not info.State.Running then
                exit_code = tonumber(info.State.ExitCode) or 0
                if exit_code ~= 0 then
                    final_status = consts.status.FAILED
                end
                stopped = true
            end
        end

        local raw_logs = docker:get_logs(docker_id, { since = log_since })
        if raw_logs then
            local lines = docker_client.parse_logs(tostring(raw_logs))
            local new_count = #lines - lines_seen
            if new_count > 0 then
                local log_db = sql.get(db_id)
                for i = lines_seen + 1, #lines do
                    local entry = lines[i]
                    local stream = entry.stream or "stdout"
                    local line_text = tostring(entry.line)
                    if log_db then
                        containers_repo.append_log(log_db, cid, stream, line_text)
                    end
                    notify_root(root_pid, consts.topic.CONTAINER_LOG, {
                        container_id = cid,
                        stream = stream,
                        line = line_text,
                    })
                end
                if log_db then log_db:release() end
                lines_seen = #lines
            end
        end

        if stopped then
            break
        end

        if poll == max_polls then
            final_status = consts.status.FAILED
            error_msg = "container polling timeout after " .. max_polls .. " attempts"
        end

        time.sleep("500ms")
    end

    -- Drain remaining logs
    for _ = 1, 5 do
        local raw_logs = docker:get_logs(docker_id, { since = log_since })
        if raw_logs then
            local lines = docker_client.parse_logs(tostring(raw_logs))
            if #lines > lines_seen then
                local drain_db = sql.get(db_id)
                for i = lines_seen + 1, #lines do
                    local entry = lines[i]
                    local stream = entry.stream or "stdout"
                    local line_text = tostring(entry.line)
                    if drain_db then
                        containers_repo.append_log(drain_db, cid, stream, line_text)
                    end
                    notify_root(root_pid, consts.topic.CONTAINER_LOG, {
                        container_id = cid,
                        stream = stream,
                        line = line_text,
                    })
                end
                if drain_db then drain_db:release() end
                lines_seen = #lines
                break
            end
        end
        time.sleep("100ms")
    end

    local update_fields: {[string]: any} = {
        exit_code = exit_code,
        stopped_at = os.time(),
    }
    if error_msg then
        update_fields.error = error_msg
    end

    local final_db = sql.get(db_id)
    if final_db then
        containers_repo.update_status(final_db, cid, final_status, update_fields)
        final_db:release()
    end

    notify_status(root_pid, cid, final_status, { exit_code = exit_code, error = error_msg })

    docker:remove_container(docker_id, true)
end

local function claim_and_run(db, docker, db_id, exec_images, active, root_pid)
    local pending = containers_repo.list_pending(db)
    if not pending then return end

    for _, c in ipairs(pending) do
        local cid: string = tostring(c.id)
        if not active[cid] then
            local claimed = containers_repo.claim(db, cid)
            if claimed then
                active[cid] = {}
                notify_status(root_pid, cid, consts.status.CLAIMED)

                local is_interactive = c.config and c.config.interactive

                if is_interactive then
                    local exec_id = exec_images[tostring(c.image)]
                    if not exec_id then
                        containers_repo.update_status(db, cid, consts.status.FAILED, {
                            error = "no executor configured for image: " .. tostring(c.image),
                            stopped_at = os.time(),
                        })
                        notify_status(root_pid, cid, consts.status.FAILED)
                        active[cid] = nil
                    else
                        coroutine.spawn(function()
                            local executor, exec_err = exec.get(tostring(exec_id))
                            if exec_err then
                                local edb = sql.get(db_id)
                                if edb then
                                    containers_repo.update_status(edb, cid, consts.status.FAILED, {
                                        error = tostring(exec_err),
                                        stopped_at = os.time(),
                                    })
                                    edb:release()
                                end
                                notify_status(root_pid, cid, consts.status.FAILED)
                            else
                                local edb = sql.get(db_id)
                                if edb then
                                    containers_repo.update_status(edb, cid, consts.status.RUNNING, {
                                        started_at = os.time(),
                                    })
                                    edb:release()
                                end
                                notify_status(root_pid, cid, consts.status.RUNNING)
                                run_interactive(executor, db_id, c, active, root_pid)
                                executor:release()
                            end
                            active[cid] = nil
                        end)
                    end
                else
                    coroutine.spawn(function()
                        run_managed(docker, db_id, c, root_pid)
                        active[cid] = nil
                    end)
                end
            end
        end
    end
end

local worker = {}

function worker.run(config: {
    db_id: string,
    socket_path: string?,
    exec_images: {[string]: string}?,
})
    local log = logger:named("docker.worker")
    local db, db_err = sql.get(config.db_id)
    if db_err then
        return nil, "failed to get database: " .. tostring(db_err)
    end

    local docker, docker_err = docker_client.new(config.socket_path)
    if docker_err then
        db:release()
        return nil, "failed to connect to Docker: " .. tostring(docker_err)
    end

    local exec_images = config.exec_images or {}
    local root_pid = process.registry.lookup(consts.registry.ROOT)

    local fallback = time.ticker(consts.defaults.FALLBACK_INTERVAL)
    local events = process.events()
    local inbox = process.inbox()
    local active: {[string]: {proc: any?}} = {}

    claim_and_run(db, docker, config.db_id, exec_images, active, root_pid)

    while true do
        local result = channel.select({
            fallback:channel():case_receive(),
            events:case_receive(),
            inbox:case_receive(),
        })

        if result.channel == events then
            if result.value.kind == process.event.CANCEL then
                break
            end
        elseif result.channel == inbox then
            local msg = result.value
            local topic = msg:topic()
            if topic == consts.topic.CONTAINER_NEW then
                claim_and_run(db, docker, config.db_id, exec_images, active, root_pid)
            elseif topic == consts.topic.STDIN then
                local payload = helpers.extract_payload(msg)
                if payload and payload.container_id and payload.data then
                    local entry = active[payload.container_id]
                    if entry and entry.proc then
                        entry.proc:write_stdin(payload.data)
                    end
                end
            end
        else
            claim_and_run(db, docker, config.db_id, exec_images, active, root_pid)
        end
    end

    fallback:stop()
    db:release()
    return { status = "worker_shutdown" }
end

return worker
