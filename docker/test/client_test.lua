local docker_client = require("docker_client")
local test = require("test")
local time = require("time")

local function define_tests()
    describe("Docker Client", function()

        describe("parse_logs", function()
            local parse_logs = docker_client.parse_logs

            it("returns empty table for nil input", function()
                local result = parse_logs(nil)
                test.not_nil(result)
                test.eq(#result, 0, "nil input produces empty result")
            end)

            it("returns empty table for empty string", function()
                local result = parse_logs("")
                test.eq(#result, 0, "empty string produces empty result")
            end)

            it("parses single stdout frame", function()
                -- stream=1 (stdout), padding=0,0,0, size=0,0,0,12, payload="hello world\n"
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, 12) .. "hello world\n"
                local result = parse_logs(frame)
                test.eq(#result, 1, "one line parsed")
                test.eq(result[1].stream, "stdout", "stream is stdout")
                test.eq(result[1].line, "hello world", "line content matches")
            end)

            it("parses single stderr frame", function()
                -- stream=2 (stderr), padding=0,0,0, size=0,0,0,6, payload="error\n"
                local frame = string.char(2, 0, 0, 0, 0, 0, 0, 6) .. "error\n"
                local result = parse_logs(frame)
                test.eq(#result, 1, "one line parsed")
                test.eq(result[1].stream, "stderr", "stream is stderr")
                test.eq(result[1].line, "error", "line content matches")
            end)

            it("parses frame without trailing newline", function()
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, 5) .. "hello"
                local result = parse_logs(frame)
                test.eq(#result, 1, "one line parsed")
                test.eq(result[1].line, "hello", "line without newline parsed")
            end)

            it("parses multiple frames", function()
                local f1 = string.char(1, 0, 0, 0, 0, 0, 0, 7) .. "line 1\n"
                local f2 = string.char(2, 0, 0, 0, 0, 0, 0, 7) .. "line 2\n"
                local f3 = string.char(1, 0, 0, 0, 0, 0, 0, 7) .. "line 3\n"
                local result = parse_logs(f1 .. f2 .. f3)
                test.eq(#result, 3, "three lines parsed")
                test.eq(result[1].stream, "stdout", "first frame is stdout")
                test.eq(result[1].line, "line 1", "first line content")
                test.eq(result[2].stream, "stderr", "second frame is stderr")
                test.eq(result[2].line, "line 2", "second line content")
                test.eq(result[3].stream, "stdout", "third frame is stdout")
                test.eq(result[3].line, "line 3", "third line content")
            end)

            it("parses multi-line payload within single frame", function()
                local payload = "line A\nline B\nline C\n"
                local size = #payload
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, size) .. payload
                local result = parse_logs(frame)
                test.eq(#result, 3, "three lines from single frame")
                test.eq(result[1].line, "line A", "first sub-line")
                test.eq(result[2].line, "line B", "second sub-line")
                test.eq(result[3].line, "line C", "third sub-line")
            end)

            it("handles large payload sizes (big-endian encoding)", function()
                -- size = 256 (0x00, 0x00, 0x01, 0x00) in big-endian
                local payload = string.rep("x", 256)
                local frame = string.char(1, 0, 0, 0, 0, 0, 1, 0) .. payload
                local result = parse_logs(frame)
                test.eq(#result, 1, "one line parsed")
                test.eq(#result[1].line, 256, "payload length matches")
            end)

            it("skips truncated frames", function()
                -- header says 100 bytes but only 5 bytes follow
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, 100) .. "short"
                local result = parse_logs(frame)
                test.eq(#result, 0, "truncated frame skipped")
            end)

            it("skips incomplete header", function()
                -- only 4 bytes, not enough for 8-byte header
                local result = parse_logs(string.char(1, 0, 0, 0))
                test.eq(#result, 0, "incomplete header skipped")
            end)

            it("treats unknown stream type as stdout", function()
                -- stream=0 (unknown) - should fall through to stdout
                local frame = string.char(0, 0, 0, 0, 0, 0, 0, 4) .. "test"
                local result = parse_logs(frame)
                test.eq(#result, 1, "one line parsed")
                test.eq(result[1].stream, "stdout", "unknown stream defaults to stdout")
            end)

            it("skips empty lines within payload", function()
                local payload = "first\n\nsecond\n"
                local size = #payload
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, size) .. payload
                local result = parse_logs(frame)
                test.eq(#result, 2, "empty lines skipped")
                test.eq(result[1].line, "first", "first line")
                test.eq(result[2].line, "second", "second line")
            end)

            it("handles interleaved stdout and stderr frames", function()
                local f1 = string.char(1, 0, 0, 0, 0, 0, 0, 4) .. "out\n"
                local f2 = string.char(2, 0, 0, 0, 0, 0, 0, 4) .. "err\n"
                local f3 = string.char(1, 0, 0, 0, 0, 0, 0, 5) .. "out2\n"
                local result = parse_logs(f1 .. f2 .. f3)
                test.eq(#result, 3, "three interleaved lines")
                test.eq(result[1].stream, "stdout")
                test.eq(result[2].stream, "stderr")
                test.eq(result[3].stream, "stdout")
            end)

            it("handles zero-length payload", function()
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, 0)
                local result = parse_logs(frame)
                test.eq(#result, 0, "zero-length payload produces no lines")
            end)

            it("handles payload with only newlines", function()
                local payload = "\n\n\n"
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, #payload) .. payload
                local result = parse_logs(frame)
                test.eq(#result, 0, "only newlines produces no lines")
            end)

            it("handles frame followed by truncated frame", function()
                local good = string.char(1, 0, 0, 0, 0, 0, 0, 6) .. "good\n\n"
                local bad = string.char(1, 0, 0, 0, 0, 0, 0, 50) .. "short"
                local result = parse_logs(good .. bad)
                test.eq(#result, 1, "only good frame parsed")
                test.eq(result[1].line, "good")
            end)

            it("handles binary content in payload", function()
                local payload = string.char(0, 255, 128, 64)
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, #payload) .. payload
                local result = parse_logs(frame)
                test.eq(#result, 1, "binary content returned as single line")
                test.eq(#result[1].line, 4, "binary payload length preserved")
            end)

            it("handles payload with carriage return", function()
                local payload = "progress: 50%\rprogress: 100%\n"
                local frame = string.char(1, 0, 0, 0, 0, 0, 0, #payload) .. payload
                local result = parse_logs(frame)
                test.eq(#result, 1, "carriage returns do not split lines")
            end)

            it("handles large size in big-endian (multi-byte)", function()
                -- size = 65536 (0x00, 0x01, 0x00, 0x00)
                local payload = string.rep("a", 65536)
                local frame = string.char(1, 0, 0, 0, 0, 1, 0, 0) .. payload
                local result = parse_logs(frame)
                test.eq(#result, 1, "large frame parsed")
                test.eq(#result[1].line, 65536, "large payload preserved")
            end)
        end)

        describe("parse_stream_lines", function()
            local parse = docker_client.parse_stream_lines

            it("returns empty table for nil input", function()
                local result = parse(nil)
                test.not_nil(result)
                test.eq(#result, 0, "nil input produces empty result")
            end)

            it("returns empty table for empty string", function()
                local result = parse("")
                test.eq(#result, 0, "empty string produces empty result")
            end)

            it("parses single JSON line", function()
                local result = parse('{"stream":"Step 1/3 : FROM alpine\\n"}\n')
                test.eq(#result, 1, "one line parsed")
                test.eq(result[1].stream, "Step 1/3 : FROM alpine\n")
            end)

            it("parses multiple JSON lines", function()
                local data = '{"stream":"line1"}\n{"stream":"line2"}\n{"status":"done"}\n'
                local result = parse(data)
                test.eq(#result, 3, "three lines parsed")
                test.eq(result[1].stream, "line1")
                test.eq(result[2].stream, "line2")
                test.eq(result[3].status, "done")
            end)

            it("strips carriage returns from line endings", function()
                local data = '{"stream":"step1"}\r\n{"stream":"step2"}\r\n'
                local result = parse(data)
                test.eq(#result, 2, "two lines parsed from CRLF input")
                test.eq(result[1].stream, "step1")
                test.eq(result[2].stream, "step2")
            end)

            it("skips invalid JSON lines", function()
                local data = '{"stream":"ok"}\nnot json\n{"status":"done"}\n'
                local result = parse(data)
                test.eq(#result, 2, "invalid JSON line skipped")
                test.eq(result[1].stream, "ok")
                test.eq(result[2].status, "done")
            end)

            it("skips empty lines", function()
                local data = '{"stream":"a"}\n\n\n{"stream":"b"}\n'
                local result = parse(data)
                test.eq(#result, 2, "empty lines skipped")
                test.eq(result[1].stream, "a")
                test.eq(result[2].stream, "b")
            end)

            it("handles line without trailing newline", function()
                local data = '{"stream":"only"}'
                local result = parse(data)
                test.eq(#result, 1, "line without trailing newline parsed")
                test.eq(result[1].stream, "only")
            end)

            it("handles pull progress output", function()
                local data = '{"status":"Pulling from library/alpine","id":"latest"}\n'
                    .. '{"status":"Downloading","progressDetail":{"current":100,"total":200},"progress":"[====>   ]","id":"abc123"}\n'
                    .. '{"status":"Download complete","id":"abc123"}\n'
                local result = parse(data)
                test.eq(#result, 3, "three pull lines parsed")
                test.eq(result[1].status, "Pulling from library/alpine")
                test.eq(result[2].progress, "[====>   ]")
                test.eq(result[3].status, "Download complete")
            end)

            it("handles error response in stream", function()
                local data = '{"stream":"Step 1/2 : FROM alpine"}\n'
                    .. '{"error":"dockerfile parse error","errorDetail":{"message":"unknown instruction"}}\n'
                local result = parse(data)
                test.eq(#result, 2, "error line parsed")
                test.eq(result[2].error, "dockerfile parse error")
            end)

            it("handles non-string input via tostring", function()
                local result = parse(42)
                test.not_nil(result, "non-string input handled")
            end)
        end)

        describe("log_decoder", function()
            local function frame(stream_byte: number, payload: string): string
                local n = #payload
                return string.char(stream_byte, 0, 0, 0,
                    math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
                    math.floor(n / 256) % 256, n % 256) .. payload
            end

            local function collect(decoder, chunks: {string}): {table}
                local out = {}
                for _, chunk in ipairs(chunks) do
                    for _, entry in ipairs(decoder:push(chunk)) do
                        table.insert(out, entry)
                    end
                end
                return out
            end

            it("decodes frames split at every byte boundary identically", function()
                local data = frame(1, "alpha\n") .. frame(2, "beta\ngamma\n") .. frame(1, "delta")
                local whole = docker_client.parse_logs(data)
                test.eq(#whole, 4, "reference parse yields four lines")
                for split = 1, #data - 1 do
                    local got = collect(docker_client.new_log_decoder(),
                        { data:sub(1, split), data:sub(split + 1) })
                    test.eq(#got, #whole, "line count with split at " .. split)
                    for i, entry in ipairs(whole) do
                        test.eq(got[i].stream, entry.stream, "stream " .. i .. " split " .. split)
                        test.eq(got[i].line, entry.line, "line " .. i .. " split " .. split)
                    end
                end
            end)

            it("emits nothing until a frame is complete", function()
                local decoder = docker_client.new_log_decoder()
                local data = frame(1, "hello\n")
                test.eq(#decoder:push(data:sub(1, 3)), 0, "partial header yields nothing")
                test.eq(#decoder:push(data:sub(4, 10)), 0, "partial payload yields nothing")
                local rest = decoder:push(data:sub(11))
                test.eq(#rest, 1, "completed frame yields its line")
                test.eq(rest[1].line, "hello")
            end)

            it("strips the per-frame timestamp and exposes it on each entry", function()
                local decoder = docker_client.new_log_decoder({ timestamps = true })
                local ts = "2026-09-17T10:00:00.000000123Z"
                local got = decoder:push(frame(2, ts .. " warn one\n") .. frame(1, ts .. " two\n"))
                test.eq(#got, 2)
                test.eq(got[1].stream, "stderr")
                test.eq(got[1].line, "warn one")
                test.eq(got[1].ts, ts)
                test.eq(got[2].line, "two")
                test.eq(got[2].ts, ts)
            end)
        end)

        describe("log_cursor", function()
            it("has no resume point before any entry is accepted", function()
                local cursor = docker_client.new_log_cursor()
                test.is_nil(cursor:since(), "no since before first entry")
            end)

            it("accepts entries in timestamp order and resumes from the last timestamp", function()
                local cursor = docker_client.new_log_cursor()
                test.is_true(cursor:accept({ ts = "2026-09-17T10:00:00.000000100Z", line = "a" }))
                test.is_true(cursor:accept({ ts = "2026-09-17T10:00:01.000000200Z", line = "b" }))
                local expected_unix = time.parse(time.RFC3339NANO, "2026-09-17T10:00:01.000000200Z"):unix()
                test.eq(cursor:since(), string.format("%d.%09d", expected_unix, 200))
            end)

            it("skips entries replayed at or before the resume point", function()
                local cursor = docker_client.new_log_cursor()
                local t1 = "2026-09-17T10:00:00.000000001Z"
                local t2 = "2026-09-17T10:00:00.000000002Z"
                test.is_true(cursor:accept({ ts = t1, line = "one" }))
                test.is_true(cursor:accept({ ts = t2, line = "two" }))
                test.is_true(cursor:accept({ ts = t2, line = "two again" }))

                -- A reconnect with since=t2 replays everything stamped t2 and later.
                cursor:reconnect()
                test.is_false(cursor:accept({ ts = t2, line = "two" }), "first replayed line at t2 skipped")
                test.is_false(cursor:accept({ ts = t2, line = "two again" }), "second replayed line at t2 skipped")
                test.is_true(cursor:accept({ ts = t2, line = "two third" }), "unseen line at t2 accepted")
                test.is_false(cursor:accept({ ts = t1, line = "one" }), "older line rejected")
                test.is_true(cursor:accept({ ts = "2026-09-17T10:00:00.000000003Z", line = "three" }))
            end)

            it("resumes a replay window only once per reconnect", function()
                local cursor = docker_client.new_log_cursor()
                local t = "2026-09-17T10:00:00.000000005Z"
                test.is_true(cursor:accept({ ts = t, line = "x" }))
                cursor:reconnect()
                test.is_false(cursor:accept({ ts = t, line = "x" }), "replayed line skipped after reconnect")
                test.is_true(cursor:accept({ ts = t, line = "y" }), "new line at same ts accepted")
                cursor:reconnect()
                test.is_false(cursor:accept({ ts = t, line = "x" }), "first replayed line skipped again")
                test.is_false(cursor:accept({ ts = t, line = "y" }), "second replayed line skipped again")
            end)
        end)

        describe("parse_response", function()
            local parse = docker_client.parse_response

            it("decodes a JSON body", function()
                local body = parse('{"Id":"abc","State":{"Running":true}}', { ["Content-Type"] = "application/json" })
                test.eq(body.Id, "abc")
                test.is_true(body.State.Running)
            end)

            it("returns a multiplexed log stream body untouched", function()
                local raw = string.char(1, 0, 0, 0, 0, 0, 0, 3) .. "hi\n"
                local body = parse(raw, { ["Content-Type"] = "application/vnd.docker.multiplexed-stream" })
                test.eq(body, raw)
            end)

            it("returns a plain text body untouched", function()
                test.eq(parse("OK", { ["Content-Type"] = "text/plain; charset=utf-8" }), "OK")
            end)
        end)
    end)
end

return test.run_cases(define_tests)
