local docker_client = require("docker_client")
local reconcile = require("reconcile")

-- Follows a managed container's log stream until the container finishes.
--
-- The daemon pushes new log frames over one long-lived request; the stream ends
-- when the container stops, the session timeout elapses, or the connection
-- drops. Only then is the container inspected: a running container is
-- re-followed from the last delivered timestamp, a stopped one yields its
-- outcome. Nothing is re-read and nothing is polled while logs flow.
--
-- Only a stream the daemon ended proves every line was delivered. When a
-- session broke and the container is found stopped, one non-follow read from
-- the last delivered timestamp collects the lines written after the break.
-- An inspect that observed nothing is not an outcome: the container is
-- followed again and the failure is reported through `warn`.

local READ_SIZE = 65536
local MAX_BACKOFF_SECONDS = 30

type WatchParams = {
    docker: any,
    docker_id: string,
    since: string?,
    is_service: boolean,
    stabilize_seconds: number,
    session_timeout: string,
    started_at: number,
    on_logs: (entries: {table}) -> (),
    warn: (message: string, fields: {[string]: any}) -> (),
    sleep: (duration: string) -> (),
    now: () -> number,
}

type WatchOutcome = {
    kind: string,
    exit_code: number?,
    error: string?,
}

local log_watch = {}

log_watch.since_of = docker_client.since_of

local function backoff(attempt: number): string
    local seconds = 2 ^ (attempt - 1)
    if seconds > MAX_BACKOFF_SECONDS then
        seconds = MAX_BACKOFF_SECONDS
    end
    return string.format("%ds", seconds)
end

-- Delivers the entries the cursor has not seen. Returns true when any were new.
local function deliver(p: WatchParams, cursor: any, entries: {table}): boolean
    local fresh = {}
    for _, entry in ipairs(entries) do
        if cursor:accept(entry) then
            table.insert(fresh, entry)
        end
    end
    if #fresh == 0 then
        return false
    end
    p.on_logs(fresh)
    return true
end

-- Reads one follow session to its end. Returns whether it delivered new lines
-- and, when the session did not end at the daemon's end of stream, why.
local function drain_session(p: WatchParams, cursor: any, since: string?): (boolean, string?)
    local reader, follow_err = p.docker:follow_logs(p.docker_id, {
        since = since,
        timeout = p.session_timeout,
    })
    if not reader or follow_err then
        return false, tostring(follow_err or "logs stream unavailable")
    end

    local decoder = docker_client.new_log_decoder({ timestamps = true })
    local delivered = false
    local broken: string? = nil
    while true do
        local chunk, read_err = reader:read(READ_SIZE)
        if read_err then
            broken = tostring(read_err)
            break
        end
        if chunk == nil then
            break
        end
        if chunk ~= "" and deliver(p, cursor, decoder:push(chunk)) then
            delivered = true
        end
    end
    reader:close()
    return delivered, broken
end

-- Reads the log of a stopped container from the last delivered timestamp.
local function read_remaining(p: WatchParams, cursor: any, since: string?)
    local raw, logs_err = p.docker:get_logs(p.docker_id, { since = since, timestamps = true })
    if logs_err then
        p.warn("final container log read failed; trailing lines may be missing", {
            docker_id = p.docker_id, error = tostring(logs_err),
        })
        return
    end
    local decoder = docker_client.new_log_decoder({ timestamps = true })
    deliver(p, cursor, decoder:push(raw and tostring(raw) or ""))
end

-- Outcome kinds:
--   exited   - the container stopped; exit_code is its status
--   vanished - the daemon reports the container does not exist
--   detached - a stabilized service stopped outside its restart policy and is
--              left to the daemon and the monitor
function log_watch.follow(p: WatchParams): WatchOutcome
    local cursor = docker_client.new_log_cursor()
    local since = p.since
    local idle_sessions: number = 0
    local outcome: WatchOutcome? = nil

    while outcome == nil do
        local delivered, broken = drain_session(p, cursor, since)
        cursor:reconnect()
        since = cursor:since() or since

        local info, absent, inspect_err = reconcile.observe(p.docker, p.docker_id)
        local waiting_for_restart = false

        if absent then
            outcome = { kind = "vanished", error = "container vanished outside the module (Docker inspect returned 404)" }
        elseif not info then
            p.warn("container inspect failed; following again", {
                docker_id = p.docker_id, error = inspect_err,
            })
        else
            local state = info.State or {}
            if not state.Running then
                local stabilized = p.is_service and (p.now() - p.started_at) >= p.stabilize_seconds
                if not stabilized then
                    outcome = { kind = "exited", exit_code = tonumber(state.ExitCode) or 0 }
                elseif not state.Restarting then
                    outcome = { kind = "detached" }
                else
                    waiting_for_restart = true
                end
            end
        end

        if outcome ~= nil then
            if broken and outcome.kind ~= "vanished" then
                read_remaining(p, cursor, since)
            end
        elseif delivered and info and not waiting_for_restart then
            idle_sessions = 0
        else
            idle_sessions = idle_sessions + 1
            p.sleep(backoff(idle_sessions))
        end
    end

    return outcome
end

return log_watch
