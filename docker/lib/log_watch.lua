local docker_client = require("docker_client")

-- Follows a managed container's log stream until the container finishes.
--
-- The daemon pushes new log frames over one long-lived request; the stream ends
-- when the container stops, the session timeout elapses, or the connection
-- drops. Only then is the container inspected: a running container is
-- re-followed from the last delivered timestamp, a stopped one yields its
-- outcome. Nothing is re-read and nothing is polled while logs flow.

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

-- Reads one follow session to its end. Returns true when it delivered new lines.
local function drain_session(p: WatchParams, cursor: any, since: string?): boolean
    local reader, follow_err = p.docker:follow_logs(p.docker_id, {
        since = since,
        timeout = p.session_timeout,
    })
    if not reader or follow_err then
        return false
    end

    local decoder = docker_client.new_log_decoder({ timestamps = true })
    local delivered = false
    while true do
        local chunk, read_err = reader:read(READ_SIZE)
        if read_err or chunk == nil then
            break
        end
        if chunk ~= "" then
            local fresh = {}
            for _, entry in ipairs(decoder:push(chunk)) do
                if cursor:accept(entry) then
                    table.insert(fresh, entry)
                end
            end
            if #fresh > 0 then
                delivered = true
                p.on_logs(fresh)
            end
        end
    end
    reader:close()
    return delivered
end

-- Outcome kinds:
--   exited   - the container stopped; exit_code is its status
--   failed   - the container state could not be read; error explains why
--   detached - a stabilized service stopped outside its restart policy and is
--              left to the daemon and the monitor
function log_watch.follow(p: WatchParams): WatchOutcome
    local cursor = docker_client.new_log_cursor()
    local since = p.since
    local idle_sessions: number = 0
    local outcome: WatchOutcome? = nil

    while outcome == nil do
        local delivered = drain_session(p, cursor, since)

        local info, inspect_err = p.docker:inspect_container(p.docker_id)
        local state = (info and info.State) or {}
        local waiting_for_restart = false

        if inspect_err then
            outcome = { kind = "failed", error = "inspect failed: " .. tostring(inspect_err) }
        elseif not state.Running then
            local stabilized = p.is_service and (p.now() - p.started_at) >= p.stabilize_seconds
            if not stabilized then
                outcome = { kind = "exited", exit_code = tonumber(state.ExitCode) or 0 }
            elseif not state.Restarting then
                outcome = { kind = "detached" }
            else
                waiting_for_restart = true
            end
        end

        if outcome == nil then
            cursor:reconnect()
            since = cursor:since() or since

            if delivered and not waiting_for_restart then
                idle_sessions = 0
            else
                idle_sessions = idle_sessions + 1
                p.sleep(backoff(idle_sessions))
            end
        end
    end

    return outcome
end

return log_watch
