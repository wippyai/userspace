local test = require("test")
local worker = require("worker")

-- Regression: when a scheduled task fails non-retriably (or exhausts retries, or
-- a once-schedule fails), the disable reason must carry the implementation's
-- error so operators see why the schedule stopped, not a bare "retriable=false".

local function define_tests()
    test.describe("scheduler worker completion reasons", function()
        -- The exported function's task param is documented as a plain table; cast
        -- to that signature so minimal test fixtures type-check (the fixpoint
        -- otherwise narrows it to the full schedule record).
        local determine = worker.determine_completion_action ::
            (task: table, exec_result: table) -> (string, string?)
        local ACTIONS = worker.COMPLETION_ACTIONS :: table

        test.it("includes the error when a recurring task is non-retriable", function()
            local action, reason = determine(
                { schedule_type = "interval", retry_count = 0, max_retries = 3 },
                { error = "no agent configured", retriable = false }
            )
            test.eq(action, ACTIONS.DISABLE)
            test.is_true(reason:find("no agent configured", 1, true) ~= nil,
                "reason must carry the error, got: " .. tostring(reason))
            test.is_true(reason ~= "Task failed with retriable=false",
                "reason must not be the bare generic flag")
        end)

        test.it("includes the error when a once-schedule fails", function()
            local action, reason = determine(
                { schedule_type = "once", retry_count = 0, max_retries = 0 },
                { error = "no actor context", retriable = false }
            )
            test.eq(action, ACTIONS.DISABLE)
            test.is_true(reason:find("no actor context", 1, true) ~= nil,
                "reason must carry the error, got: " .. tostring(reason))
        end)

        test.it("includes the error when retries are exhausted", function()
            local action, reason = determine(
                { schedule_type = "interval", retry_count = 3, max_retries = 3 },
                { error = "downstream timeout", retriable = true }
            )
            test.eq(action, ACTIONS.DISABLE)
            test.is_true(reason:find("downstream timeout", 1, true) ~= nil,
                "reason must carry the error, got: " .. tostring(reason))
            test.is_true(reason:find("Maximum retries", 1, true) ~= nil,
                "reason must still note the retry exhaustion")
        end)

        test.it("reschedules a successful recurring task", function()
            local action = determine(
                { schedule_type = "interval", retry_count = 0, max_retries = 3 },
                { error = nil, retriable = nil }
            )
            test.eq(action, ACTIONS.RESCHEDULE)
        end)

        test.it("retries a retriable recurring task with budget left", function()
            local action = determine(
                { schedule_type = "interval", retry_count = 1, max_retries = 3 },
                { error = "transient", retriable = true }
            )
            test.eq(action, ACTIONS.RETRY)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options)
    return run_cases(options)
end

return { run = run }
