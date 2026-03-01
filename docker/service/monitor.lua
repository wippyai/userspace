local sql = require("sql")
local time = require("time")
local consts = require("consts")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")

local logger = require("logger")

local monitor = {}

function monitor.run(config: {
    db_id: string,
    socket_path: string?,
    monitor_interval: string?,
    log_ttl: number?,
})
    local log = logger:named("docker.monitor")
    local db, db_err = sql.get(config.db_id)
    if db_err then
        return nil, "failed to get database: " .. tostring(db_err)
    end

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
            local old = containers_repo.list(db, {
                status = consts.status.STOPPED,
                limit = 100,
            })
            for _, c in ipairs(old or {}) do
                if c.stopped_at and (os.time() - c.stopped_at) > log_ttl then
                    if docker then
                        if c.docker_id and c.docker_id ~= "" then
                            local _, rm_err = (docker :: {[string]: any}):remove_container(tostring(c.docker_id), true)
                            if rm_err then
                                log:warn("failed to remove container", { docker_id = c.docker_id, error = tostring(rm_err) })
                            end
                        end
                    end
                    containers_repo.delete(db, tostring(c.id))
                end
            end

            local failed = containers_repo.list(db, {
                status = consts.status.FAILED,
                limit = 100,
            })
            for _, c in ipairs(failed or {}) do
                if c.stopped_at and (os.time() - c.stopped_at) > log_ttl then
                    if docker then
                        if c.docker_id and c.docker_id ~= "" then
                            local _, rm_err = (docker :: {[string]: any}):remove_container(tostring(c.docker_id), true)
                            if rm_err then
                                log:warn("failed to remove container", { docker_id = c.docker_id, error = tostring(rm_err) })
                            end
                        end
                    end
                    containers_repo.delete(db, tostring(c.id))
                end
            end
        end
    end

    ticker:stop()
    db:release()
    return { status = "monitor_shutdown" }
end

return monitor
