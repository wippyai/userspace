local test = require("test")
local runner = require("runner")

local DB = "app:db"

local function define_tests()
    describe("uploads migrations", function()
        it("apply completely on sqlite", function()
            local r = runner.setup(DB)
            local _, run_err = r:run()
            test.is_nil(run_err, "pending migrations applied")

            local status = r:status()
            local uploads_seen = 0
            for _, m in ipairs(status.migrations or {}) do
                if tostring(m.id):find("^userspace%.uploads%.migrations:") then
                    uploads_seen = uploads_seen + 1
                    test.eq(m.status, "applied", tostring(m.id) .. " applied")
                end
            end
            test.ok(uploads_seen >= 4, "uploads migrations discovered: " .. uploads_seen)
            test.eq(tonumber(status.pending_migrations), 0, "nothing left pending")
        end)
    end)
end

return test.run_cases(define_tests)
