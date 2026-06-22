local test = require("test")
local json = require("json")
local api_error = require("api_error")

local function new_fake_res()
    local captured = {}
    local res = {
        set_status = function(_, status) captured.status = status end,
        write_json = function(_, body) captured.body = body end,
    }
    return res, captured
end

local function define_tests()
    test.describe("api_error.fail sanitization", function()
        test.it("omits details and never echoes the raw error", function()
            local res, captured = new_fake_res()
            local secret = "user= password=SUPER_SECRET_RDS_VALUE"

            api_error.fail(res, 500, "Internal error", secret)

            test.eq(captured.status, 500)
            test.not_nil(captured.body)
            test.eq(captured.body.success, false)
            test.eq(captured.body.error, "Internal error")
            test.is_nil(captured.body.details)

            local encoded = json.encode(captured.body)
            test.is_nil(string.find(encoded, "SUPER_SECRET_RDS_VALUE", 1, true))
        end)

        test.it("returns the public message with a nil error", function()
            local res, captured = new_fake_res()

            api_error.fail(res, 404, "Upload not found", nil)

            test.eq(captured.status, 404)
            test.eq(captured.body.error, "Upload not found")
            test.is_nil(captured.body.details)
        end)
    end)
end

return test.run_cases(define_tests)
