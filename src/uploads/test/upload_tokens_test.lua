local test = require("test")
local upload_tokens = require("upload_tokens")
local base64 = require("base64")

local function define_tests()
    describe("Upload Tokens", function()
        it("should round-trip pack and unpack with all fields", function()
            local params = {
                function_id = "kb.ingest:on_upload_complete",
                on_error_id = "kb.ingest:on_upload_error",
                params = { kb_id = "abc-123", tags = { "doc", "pdf" } },
                actor_id = "user-uuid-001",
                actor_scope = "tenant-scope",
            }

            local token, err = upload_tokens.pack(params)
            test.is_nil(err)
            test.not_nil(token)

            local result, err = upload_tokens.unpack(token :: string)
            test.is_nil(err)
            test.is_table(result)

            test.eq(result.function_id, params.function_id)
            test.eq(result.on_error_id, params.on_error_id)
            test.eq(result.actor_id, params.actor_id)
            test.eq(result.actor_scope, params.actor_scope)
            test.is_number(result.issued_at)
            test.eq(result.params.kb_id, "abc-123")
            test.eq(#result.params.tags, 2)
        end)

        it("should pack with only required fields", function()
            local params = {
                function_id = "my.module:handler",
                actor_id = "user-123",
                actor_scope = "default",
            }

            local token, err = upload_tokens.pack(params)
            test.is_nil(err)
            test.not_nil(token)

            local result, err = upload_tokens.unpack(token :: string)
            test.is_nil(err)
            test.eq(result.function_id, "my.module:handler")
            test.eq(result.actor_id, "user-123")
            test.eq(result.actor_scope, "default")
            test.is_nil(result.on_error_id)
            test.is_nil(result.params)
        end)

        it("should error on missing function_id", function()
            local token, err = upload_tokens.pack({
                actor_id = "user-123",
                actor_scope = "default",
            })
            test.is_nil(token)
            test.not_nil(err)
            test.contains(tostring(err), "function_id is required")
        end)

        it("should error on missing actor_id", function()
            local token, err = upload_tokens.pack({
                function_id = "my.module:handler",
                actor_scope = "default",
            })
            test.is_nil(token)
            test.not_nil(err)
            test.contains(tostring(err), "actor_id is required")
        end)

        it("should error on missing actor_scope", function()
            local token, err = upload_tokens.pack({
                function_id = "my.module:handler",
                actor_id = "user-123",
            })
            test.is_nil(token)
            test.not_nil(err)
            test.contains(tostring(err), "actor_scope is required")
        end)

        it("should error on non-table params", function()
            local token, err = upload_tokens.pack("not a table")
            test.is_nil(token)
            test.not_nil(err)
            test.contains(tostring(err), "Parameters must be provided as a table")
        end)

        it("should error on nil token", function()
            local result, err = upload_tokens.unpack(nil)
            test.is_nil(result)
            test.not_nil(err)
            test.contains(tostring(err), "No token provided")
        end)

        it("should error on invalid token format", function()
            local result, err = upload_tokens.unpack("not a valid token")
            test.is_nil(result)
            test.not_nil(err)
            test.contains(tostring(err), "Invalid token format")
        end)

        it("should error on corrupted base64 data", function()
            local result, err = upload_tokens.unpack(base64.encode("random garbage data"))
            test.is_nil(result)
            test.not_nil(err)
        end)

        it("should detect expired tokens", function()
            mock("os.time", function() return 1740700000 end)

            local params = {
                function_id = "kb.ingest:handler",
                actor_id = "user-123",
                actor_scope = "default",
            }

            local token, _ = upload_tokens.pack(params)

            mock("os.time", function() return 1740700000 + 90000 end)

            local result, err = upload_tokens.unpack(token :: string)
            test.is_nil(result)
            test.not_nil(err)
            test.contains(tostring(err), "Token expired")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
