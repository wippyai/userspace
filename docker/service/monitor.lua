local sql = require("sql")
local time = require("time")
local registry = require("registry")
local consts = require("consts")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")
local reconcile = require("reconcile")

local logger = require("logger")

local monitor = {}

local function reconcile_vanished_rows(db, docker, log)
    if not docker then
        return
    end

    local declared_ids = {}
    local declared, decl_err = registry.find({ ["meta.type"] = "docker.container" })
    if not decl_err then
        for _, entry in ipairs(declared or {}) do
            declared_ids[entry.id] = true
        end
    end

    for _, status in ipairs({ consts.status.PENDING, consts.status.CLAIMED, consts.status.RUNNING, consts.status.PAUSED }) do
        local rows = containers_repo.list(db, { status = status, limit = 100 })
        for _, row in ipairs(rows or {}) do
            if not declared_ids[row.id] then
                local vanished, inspect_err = reconcile.is_vanished(row, docker)
                if vanished then
                    local reason = "container vanished outside the module (Docker inspect returned 404)"
                    local update_err = containers_repo.update_status(db, tostring(row.id), consts.status.REMOVED, {
                        error = reason,
                        stopped_at = os.time(),
                    })
                    if update_err then
                        log:warn("failed to mark vanished container removed", {
                            id = tostring(row.id), error = tostring(update_err),
                        })
                    else
                        log:warn("container vanished outside the module", { id = tostring(row.id) })
                    end
                elseif inspect_err then
                    log:warn("container inspect failed during reconciliation", {
                        id = tostring(row.id), error = inspect_err,
                    })
                end
            end
        end
    end
end

function monitor.run(config: {
    db_id: string,
    socket_path: string?,
    monitor_interval: string?,
    log_ttl: number?,
})
    local log = logger:named("docker.monitor")

    local docker, docker_err = docker_client.new(config.socket_path)
    if docker_err then
        log:warn("Docker client unavailable, cleanup limited", { error = tostring(docker_err) })
    end

    local monitor_interval = config.monitor_interval or consts.defaults.MONITOR_INTERVAL
    local log_ttl = config.log_ttl or consts.defaults.LOG_TTL

    -- Reconcile persisted rows before waiting for the first monitor interval.
    local startup_db, startup_db_err = sql.get(config.db_id)
    if startup_db_err then
        log:warn("startup reconciliation: db unavailable", { error = tostring(startup_db_err) })
    else
        reconcile_vanished_rows(startup_db, docker, log)
        startup_db:release()
    end

    local ticker = time.ticker(monitor_interval)
    local events = process.events()

    while true do
        local result = channel.select({
            ticker:channel():case_receive(),
            events:case_receive(),
        })

        if result.channel == events then
            if result.value.kind == process.event.CANCEL then
                break
            end
        else
            local db, db_err = sql.get(config.db_id)
            if db_err then
                log:warn("monitor tick: db unavailable", { error = tostring(db_err) })
            else
                reconcile_vanished_rows(db, docker, log)

                -- Clean stopped containers past TTL
                local old = containers_repo.list(db, {
                    status = consts.status.STOPPED,
                    limit = 100,
                })
                for _, c in ipairs(old or {}) do
                    if c.stopped_at and (os.time() - c.stopped_at) > log_ttl then
                        if docker and c.docker_id and c.docker_id ~= "" then
                            (docker :: {[string]: any}):remove_container(tostring(c.docker_id), true)
                        end
                        containers_repo.delete(db, tostring(c.id))
                    end
                end

                -- Clean failed and removed containers past TTL
                for _, status in ipairs({ consts.status.FAILED, consts.status.REMOVED }) do
                    local stale = containers_repo.list(db, {
                        status = status,
                        limit = 100,
                    })
                    for _, c in ipairs(stale or {}) do
                        local age = c.stopped_at and (os.time() - c.stopped_at) or (c.created_at and (os.time() - c.created_at) or 0)
                        if age > log_ttl then
                            if docker and c.docker_id and c.docker_id ~= "" then
                                (docker :: {[string]: any}):remove_container(tostring(c.docker_id), true)
                            end
                            containers_repo.delete(db, tostring(c.id))
                        end
                    end
                end

                -- Runtime recovery: requeue declared containers marked running whose
                -- container has vanished (removed, or restart retries exhausted).
                -- Docker's restart policy handles an ordinary crash; this catches the
                -- cases it can't. The worker's fallback poll then recreates.
                local declared, decl_err = registry.find({ ["meta.type"] = "docker.container" })
                if not decl_err then
                    for _, entry in ipairs(declared or {}) do
                        local row = containers_repo.get(db, entry.id)
                        local alive = false
                        if row and docker and row.docker_id and tostring(row.docker_id) ~= "" then
                            local info = (docker :: {[string]: any}):inspect_container(tostring(row.docker_id))
                            alive = (info and info.State and info.State.Running) and true or false
                        end
                        if row and reconcile.needs_requeue(row, alive) then
                            log:warn("declared container vanished; requeueing", { id = entry.id })
                            containers_repo.update_status(db, tostring(row.id), consts.status.PENDING, {})
                        end
                    end
                end

                db:release()
            end
        end
    end

    ticker:stop()
    return { status = "monitor_shutdown" }
end

return monitor
