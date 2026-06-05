local sql = require("sql")
local time = require("time")
local registry = require("registry")
local consts = require("consts")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")
local reconcile = require("reconcile")

local logger = require("logger")

local monitor = {}

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
