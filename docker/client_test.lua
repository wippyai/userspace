local docker_client = require("docker_client")
local test = require("test")

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
    end)
end

return test.run_cases(define_tests)
