local test = require("test")
local callback_handler = require("callback_handler")

-- Stub http request. The wippy runtime returns "" (empty string) for a missing
-- query param, so the stub mirrors that: any param not provided reads back "".
local function stub_req(params, opts)
    opts = opts or {}
    return {
        query = function(_, name)
            local value = params[name]
            if value == nil then
                return ""
            end
            return value
        end,
        method = function() return opts.method or "GET" end,
        is_content_type = function() return false end,
        body_json = function() return nil, "no body" end
    }
end

local function define_tests()
    describe("OAuth callback parameter extraction", function()
        it("treats a missing error param (empty string) as no error", function()
            -- Google's success redirect carries code + state and NO error param;
            -- the runtime hands that absent param back as "". Without
            -- normalization "" is truthy and a successful callback is rejected
            -- as an empty "OAuth provider error".
            local data = callback_handler._extract_callback_parameters(
                stub_req({ code = "4/0AeoWuM-success", state = "state-token-123" })
            )
            expect(data.error).to_be_nil()
            expect(data.code).to_equal("4/0AeoWuM-success")
            expect(data.state).to_equal("state-token-123")
        end)

        it("preserves a real provider error and its description", function()
            local data = callback_handler._extract_callback_parameters(
                stub_req({
                    state = "state-token-123",
                    error = "access_denied",
                    error_description = "The user denied the request"
                })
            )
            expect(data.error).to_equal("access_denied")
            expect(data.error_description).to_equal("The user denied the request")
        end)

        it("normalizes every absent param to nil", function()
            local data = callback_handler._extract_callback_parameters(stub_req({}))
            expect(data.code).to_be_nil()
            expect(data.state).to_be_nil()
            expect(data.error).to_be_nil()
            expect(data.error_description).to_be_nil()
        end)

        it("blank_to_nil collapses nil and empty string, keeps real values", function()
            expect(callback_handler._blank_to_nil(nil)).to_be_nil()
            expect(callback_handler._blank_to_nil("")).to_be_nil()
            expect(callback_handler._blank_to_nil("x")).to_equal("x")
        end)
    end)
end

return test.run_cases(define_tests)
