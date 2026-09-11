local test = require("test")
local update_schedule_func = require("update_schedule_func")

local function revive(existing, requested_enabled)
    if type(update_schedule_func.revive_updates) ~= "function" then
        error("update_schedule_func.revive_updates is missing -- a schedule that was retired can be " ..
            "switched back on in the UI but will never run again: claim_ready_tasks only takes " ..
            "status='scheduled' and nothing resets it")
    end
    return update_schedule_func.revive_updates(existing, requested_enabled)
end

local function define_tests()
    test.describe("revive_updates", function()

        test.it("brings a retired schedule back into rotation", function()
            -- claim_ready_tasks only takes status='scheduled', so flipping
            -- `enabled` alone left a row that reads as ON and never runs.
            for _, status in ipairs({ "disabled", "failed", "completed" }) do
                local u = revive({ status = status, enabled = false }, true)
                test.eq(u.status, "scheduled", "re-enabling a '" .. status .. "' schedule must reset status")
                test.eq(u.retry_count, 0, status)
                test.eq(u.consecutive_failures, 0, status)
            end
        end)

        test.it("does not touch status when disabling", function()
            -- This is what makes the app's soft delete survivable: it switches a
            -- schedule off without giving it a terminal status, so the reaper
            -- never sees it.
            local u = revive({ status = "scheduled", enabled = true }, false)
            test.is_nil(u.status)
            test.is_nil(u.retry_count)
        end)

        test.it("does not revive a schedule that is already runnable", function()
            local u = revive({ status = "scheduled", enabled = false }, true)
            test.is_nil(u.status, "an enabled-only change must not rewrite a live status")
        end)

        test.it("does nothing when the request does not change enabled", function()
            test.is_nil(revive({ status = "disabled", enabled = false }, nil).status)
            test.is_nil(revive({ status = "disabled", enabled = false }, false).status)
        end)

        test.it("tolerates a missing schedule", function()
            test.is_nil(revive(nil, true).status)
        end)

        test.it("declares status as a field it may write", function()
            -- Without this the revived status is dropped before it reaches the repo.
            local fields = update_schedule_func.UPDATEABLE_FIELDS
            if type(fields) ~= "table" then
                error("update_schedule_func.UPDATEABLE_FIELDS is missing -- the revived status is " ..
                    "dropped before it reaches the repo")
            end

            local has = {}
            for _, f in ipairs(fields) do has[f] = true end
            test.is_true(has.status, "status must be writable")
            test.is_true(has.retry_count, "retry_count must be writable")
            test.is_true(has.consecutive_failures, "consecutive_failures must be writable")

            -- ...but a caller must not be able to set it directly.
            for _, f in ipairs(update_schedule_func.REQUEST_FIELDS) do
                test.is_true(f ~= "status", "status must not be caller-settable")
            end
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
