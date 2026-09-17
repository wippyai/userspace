local test = require("test")
local log_watch = require("log_watch")

local function frame(stream_byte: number, payload: string): string
    local n = #payload
    return string.char(stream_byte, 0, 0, 0,
        math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256) .. payload
end

local function ts(n: number): string
    return string.format("2026-09-17T10:00:00.%09dZ", n)
end

local function line(n: number, text: string, stream_byte: number?): string
    return frame(stream_byte or 1, ts(n) .. " " .. text .. "\n")
end

-- A reader serving fixed chunks, then EOF.
local function reader(chunks: {string})
    local i = 0
    local r = { closed = false }
    function r:read(_size)
        i = i + 1
        return chunks[i], nil
    end
    function r:close()
        self.closed = true
        return true
    end
    return r
end

-- A Docker client double: each follow_logs call consumes the next session,
-- each inspect_container call consumes the next state.
type FakeDocker = {
    follows: {{id: string, since: string?}},
    inspects: number,
    readers: {{closed: boolean}},
}

local function fake_docker(sessions: {any}, states: {any})
    local d = {
        follows = {} :: {{id: string, since: string?}},
        inspects = 0,
        readers = {} :: {{closed: boolean}},
    }
    function d:follow_logs(id, opts)
        table.insert(self.follows, { id = id, since = opts and opts.since })
        local s = table.remove(sessions, 1)
        if s == nil then error("unexpected follow_logs call") end
        if s.err then return nil, s.err end
        local r = reader(s.chunks)
        table.insert(self.readers, r)
        return r, nil
    end
    function d:inspect_container(_id)
        self.inspects = self.inspects + 1
        local st = table.remove(states, 1)
        if st == nil then error("unexpected inspect_container call") end
        if st.err then return nil, st.err end
        return { State = st }, nil
    end
    return d
end

type RunOverrides = {since: string?, is_service: boolean?, now: (() -> number)?}

local function run(docker: any, overrides: RunOverrides?): (any, {{stream: string, line: string}}, {string})
    local o: RunOverrides = overrides or {}
    local got: {{stream: string, line: string}} = {}
    local sleeps: {string} = {}
    local function clock(): number
        return 100
    end
    local outcome = log_watch.follow({
        docker = docker,
        docker_id = "cid",
        since = o.since,
        is_service = o.is_service == true,
        stabilize_seconds = 3,
        session_timeout = "1h",
        started_at = 100,
        on_logs = function(entries: {table})
            for _, e in ipairs(entries) do
                table.insert(got, { stream = tostring(e.stream), line = tostring(e.line) })
            end
        end,
        sleep = function(d: string)
            table.insert(sleeps, d)
        end,
        now = o.now or clock,
    })
    return outcome, got, sleeps
end

local function define_tests()
    describe("log_watch.follow", function()
        it("streams a job to exit with one follow and one inspect", function()
            local docker = fake_docker({
                { chunks = { line(1, "one") .. line(2, "two", 2):sub(1, 5), line(2, "two", 2):sub(6), line(3, "three") } },
            }, {
                { Running = false, ExitCode = 0 },
            })
            local outcome, got, sleeps = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(outcome.exit_code, 0)
            test.eq(#got, 3)
            test.eq(got[1].line, "one")
            test.eq(got[2].stream, "stderr")
            test.eq(got[3].line, "three")
            test.eq(#docker.follows, 1, "single follow session")
            test.is_nil(docker.follows[1].since, "first session starts at container start")
            test.eq(docker.inspects, 1, "inspected only after the stream ended")
            test.eq(#sleeps, 0, "no sleeping while logs stream")
            test.is_true(docker.readers[1].closed, "reader closed")
        end)

        it("reports a non-zero exit code", function()
            local docker = fake_docker({ { chunks = { line(1, "boom") } } }, { { Running = false, ExitCode = 42 } })
            local outcome = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(outcome.exit_code, 42)
        end)

        it("passes the initial since through", function()
            local docker = fake_docker({ { chunks = {} } }, { { Running = false, ExitCode = 0 } })
            run(docker, { since = "1789657000" })
            test.eq(docker.follows[1].since, "1789657000")
        end)

        it("resumes after a dropped session without duplicating or losing lines", function()
            local docker = fake_docker({
                { chunks = { line(1, "a") .. line(2, "b") } },
                { chunks = { line(2, "b") .. line(2, "b2") .. line(3, "c") } },
            }, {
                { Running = true },
                { Running = false, ExitCode = 0 },
            })
            local outcome, got, sleeps = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(#got, 4)
            test.eq(got[1].line, "a")
            test.eq(got[2].line, "b")
            test.eq(got[3].line, "b2")
            test.eq(got[4].line, "c")
            test.eq(#docker.follows, 2)
            local expected_since = log_watch.since_of(ts(2))
            test.eq(docker.follows[2].since, expected_since, "resume from last timestamp")
            test.eq(#sleeps, 0, "a session that delivered data reconnects immediately")
        end)

        it("backs off when follow fails and retries", function()
            local docker = fake_docker({
                { err = "connection refused" },
                { err = "connection refused" },
                { chunks = { line(1, "up") } },
            }, {
                { Running = true },
                { Running = true },
                { Running = false, ExitCode = 0 },
            })
            local outcome, got, sleeps = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(#got, 1)
            test.eq(sleeps[1], "1s")
            test.eq(sleeps[2], "2s")
            test.eq(#sleeps, 2)
        end)

        it("backs off when a running container ends a session without data", function()
            local docker = fake_docker({
                { chunks = {} },
                { chunks = { line(1, "late") } },
            }, {
                { Running = true },
                { Running = false, ExitCode = 0 },
            })
            local _, got, sleeps = run(docker)
            test.eq(#got, 1)
            test.eq(#sleeps, 1)
            test.eq(sleeps[1], "1s")
        end)

        it("fails when the container cannot be inspected", function()
            local docker = fake_docker({ { chunks = { line(1, "x") } } }, { { err = "no such container" } })
            local outcome = run(docker)
            test.eq(outcome.kind, "failed")
            test.eq(outcome.error, "inspect failed: no such container")
        end)

        it("treats a service that exits inside the stabilization window as a finished job", function()
            local docker = fake_docker({ { chunks = { line(1, "crash") } } }, { { Running = false, ExitCode = 3 } })
            local outcome = run(docker, { is_service = true, now = function() return 101 end })
            test.eq(outcome.kind, "exited")
            test.eq(outcome.exit_code, 3)
        end)

        it("keeps following a stable service across a restart", function()
            local docker = fake_docker({
                { chunks = { line(1, "boot") } },
                { chunks = { line(2, "boot again") } },
            }, {
                { Running = false, Restarting = true },
                { Running = false, Restarting = false },
            })
            local outcome, got, sleeps = run(docker, { is_service = true, now = function() return 200 end })
            test.eq(outcome.kind, "detached", "stopped service is left to its restart policy")
            test.eq(#got, 2)
            test.eq(got[2].line, "boot again")
            test.eq(#docker.follows, 2)
            test.eq(sleeps[1], "1s", "wait for the daemon to restart the service")
        end)
    end)
end

return test.run_cases(define_tests)
