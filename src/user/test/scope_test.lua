local test = require("test")
local scope = require("scope")
local consts = require("consts")

local function define_tests()
    local config = consts.get_config()

    test.describe("scope.resolve", function()
        test.it("admin group wins even when it is not the last group seen", function()
            local resolved = scope.resolve({ "group-a", config.admin_group_id, "group-b" })
            test.eq(resolved, config.admin_group_id)
        end)

        test.it("admin group wins even when it is the first group seen", function()
            local resolved = scope.resolve({ config.admin_group_id, "group-a", "group-b" })
            test.eq(resolved, config.admin_group_id)
        end)

        test.it("non-admin groups resolve to the last group seen", function()
            local resolved = scope.resolve({ "group-a", "group-b", "group-c" })
            test.eq(resolved, "group-c")
        end)

        test.it("nil groups resolve to the default group", function()
            local resolved = scope.resolve(nil)
            test.eq(resolved, config.default_group_id)
        end)

        test.it("empty groups resolve to the default group", function()
            local resolved = scope.resolve({})
            test.eq(resolved, config.default_group_id)
        end)
    end)
end

return test.run_cases(define_tests)
