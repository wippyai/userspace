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

-- A reader serving fixed chunks, then EOF, or `read_err` when the session
-- breaks instead of ending.
local function reader(chunks: {string}, read_err: string?)
    local i = 0
    local r = { closed = false }
    function r:read(_size)
        i = i + 1
        if chunks[i] == nil and read_err then
            return nil, read_err
        end
        return chunks[i], nil
    end
    function r:close()
        self.closed = true
        return true
    end
    return r
end

-- A Docker client double: each follow_logs call consumes the next session,
-- each inspect_container call the next state and each get_logs call the next
-- read. Inspect failures carry the HTTP status the real client returns.
type FakeDocker = {
    follows: {{id: string, since: string?}},
    inspects: number,
    readers: {{closed: boolean}},
    reads: {{id: string, since: string?, timestamps: boolean?}},
}

type LogSession = {chunks: {string}?, err: string?, read_err: string?}
type ContainerState = {Running: boolean?, Restarting: boolean?, ExitCode: number?, err: string?, status: number?}
type LogRead = {raw: string?, err: string?}

local function fake_docker(sessions: {LogSession}, states: {ContainerState}, reads: {LogRead}?)
    local pending_reads: {LogRead} = reads or {}
    local d = {
        follows = {} :: {{id: string, since: string?}},
        inspects = 0,
        readers = {} :: {{closed: boolean}},
        reads = {} :: {{id: string, since: string?, timestamps: boolean?}},
    }
    function d:follow_logs(id, opts)
        table.insert(self.follows, { id = id, since = opts and opts.since })
        local s = table.remove(sessions, 1)
        if s == nil then error("unexpected follow_logs call") end
        if s.err then return nil, s.err end
        if not s.chunks then error("missing follow_logs chunks") end
        local r = reader(s.chunks, s.read_err)
        table.insert(self.readers, r)
        return r, nil
    end
    function d:inspect_container(_id)
        self.inspects = self.inspects + 1
        local st = table.remove(states, 1)
        if st == nil then error("unexpected inspect_container call") end
        if st.err then return nil, st.err, st.status end
        return { State = st }, nil, 200
    end
    function d:get_logs(id, opts)
        table.insert(self.reads, { id = id, since = opts and opts.since, timestamps = opts and opts.timestamps })
        local rd = table.remove(pending_reads, 1)
        if rd == nil then error("unexpected get_logs call") end
        if rd.err then return nil, rd.err end
        return rd.raw, nil
    end
    return d
end

type RunOverrides = {since: string?, is_service: boolean?, now: (() -> number)?}

type Warning = {message: string, fields: {[string]: any}}

local function run(docker: any, overrides: RunOverrides?): (any, {{stream: string, line: string}}, {string}, {Warning})
    local o: RunOverrides = overrides or {}
    local got: {{stream: string, line: string}} = {}
    local sleeps: {string} = {}
    local warnings: {Warning} = {}
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
        warn = function(message: string, fields: {[string]: any})
            table.insert(warnings, { message = message, fields = fields })
        end,
        sleep = function(d: string)
            table.insert(sleeps, d)
        end,
        now = o.now or clock,
    })
    return outcome, got, sleeps, warnings
end

local function lines_of(got: {{stream: string, line: string}}): string
    local out: {string} = {}
    for _, g in ipairs(got) do
        table.insert(out, g.line)
    end
    return table.concat(out, ",")
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
            test.eq(#docker.reads, 0, "a session the daemon ended needs no final read")
        end)

        it("delivers a stderr line stamped before the preceding stdout line", function()
            local docker = fake_docker({
                { chunks = { line(2, "a") .. line(1, "last", 2) } },
            }, {
                { Running = false, ExitCode = 0 },
            })
            local outcome, got = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(lines_of(got), "a,last", "streams are stamped independently")
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
                { chunks = { line(1, "a") .. line(1, "err", 2) .. line(2, "b") } },
                { chunks = { line(1, "a") .. line(1, "err", 2) .. line(2, "b") .. line(2, "b2") .. line(3, "c") } },
            }, {
                { Running = true },
                { Running = false, ExitCode = 0 },
            })
            local outcome, got, sleeps = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(lines_of(got), "a,err,b,b2,c")
            test.eq(#docker.follows, 2)
            local expected_since = log_watch.since_of(ts(1))
            test.eq(docker.follows[2].since, expected_since, "resume from the earliest stream position")
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

        it("keeps following a running container across a transient inspect failure", function()
            local docker = fake_docker({
                { chunks = { line(1, "before") } },
                { chunks = { line(1, "before") .. line(2, "after") } },
            }, {
                { err = "context deadline exceeded" },
                { Running = false, ExitCode = 0 },
            })
            local outcome, got, sleeps, warnings = run(docker)
            test.eq(outcome.kind, "exited", "an unobserved state is not an outcome")
            test.eq(outcome.exit_code, 0)
            test.eq(lines_of(got), "before,after")
            test.eq(#docker.follows, 2, "re-followed after the failed inspect")
            test.is_nil(docker.follows[2].since, "stderr unseen: resume from the watch start")
            test.eq(#sleeps, 1, "backs off while the daemon errors")
            test.eq(#warnings, 1, "the inspect failure is reported")
            test.eq(warnings[1].fields.error, "context deadline exceeded")
        end)

        it("does not treat a daemon error status as a container outcome", function()
            local docker = fake_docker({
                { chunks = { line(1, "x") } },
                { chunks = {} },
            }, {
                { err = "HTTP 500: internal server error", status = 500 },
                { Running = false, ExitCode = 4 },
            })
            local outcome, _, _, warnings = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(outcome.exit_code, 4)
            test.eq(#warnings, 1)
            test.eq(warnings[1].fields.error, "HTTP 500: internal server error")
        end)

        it("reports a removed Docker container as vanished", function()
            local docker = fake_docker({ { chunks = { line(1, "x") } } }, {
                { err = "HTTP 404: No such container: missing-id", status = 404 },
            })
            local outcome = run(docker)
            test.eq(outcome.kind, "vanished")
            test.contains(outcome.error, "vanished")
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

        it("reads the rest of the log when a session breaks before the container exits", function()
            local docker = fake_docker({
                { chunks = { line(1, "a") .. line(2, "b", 2), line(3, "c"):sub(1, 6) }, read_err = "context deadline exceeded" },
            }, {
                { Running = false, ExitCode = 0 },
            }, {
                { raw = line(1, "a") .. line(2, "b", 2) .. line(3, "c") .. line(4, "d") },
            })
            local outcome, got, _, warnings = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(lines_of(got), "a,b,c,d", "trailing lines captured once")
            test.eq(#docker.follows, 1)
            test.eq(#docker.reads, 1, "one final read")
            test.eq(docker.reads[1].since, log_watch.since_of(ts(1)), "final read resumes from the earliest stream position")
            test.is_true(docker.reads[1].timestamps, "final read carries timestamps for de-duplication")
            test.eq(#warnings, 0)
        end)

        it("reads the whole log when the follow cannot be opened for a stopped container", function()
            local docker = fake_docker({
                { err = "context deadline exceeded" },
            }, {
                { Running = false, ExitCode = 7 },
            }, {
                { raw = line(1, "x") .. line(2, "y") },
            })
            local outcome, got = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(outcome.exit_code, 7)
            test.eq(lines_of(got), "x,y")
            test.is_nil(docker.reads[1].since, "nothing delivered yet: read from the start")
        end)

        it("reads the rest of the log before detaching a stabilized service", function()
            local docker = fake_docker({
                { chunks = { line(1, "boot") }, read_err = "unexpected EOF" },
            }, {
                { Running = false, Restarting = false },
            }, {
                { raw = line(1, "boot") .. line(2, "shutdown") },
            })
            local outcome, got = run(docker, { is_service = true, now = function() return 200 end })
            test.eq(outcome.kind, "detached")
            test.eq(lines_of(got), "boot,shutdown")
        end)

        it("reports a failed final read and keeps the observed exit", function()
            local docker = fake_docker({
                { chunks = { line(1, "a") }, read_err = "connection reset by peer" },
            }, {
                { Running = false, ExitCode = 0 },
            }, {
                { err = "HTTP 500: logs unavailable" },
            })
            local outcome, got, _, warnings = run(docker)
            test.eq(outcome.kind, "exited")
            test.eq(outcome.exit_code, 0)
            test.eq(lines_of(got), "a")
            test.eq(#warnings, 1, "the lost tail is reported")
            test.eq(warnings[1].fields.error, "HTTP 500: logs unavailable")
        end)
    end)
end

return test.run_cases(define_tests)
