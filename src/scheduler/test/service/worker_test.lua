local test = require("test")
local worker = require("worker")

local function define_tests()
    test.describe("scheduler worker completion reasons", function()
        -- The exported function's task param is documented as a plain table; cast
        -- to that signature so minimal test fixtures type-check (the fixpoint
        -- otherwise narrows it to the full schedule record).
        local determine = worker.determine_completion_action ::
            (task: table, exec_result: table) -> (string, string?)
        local ACTIONS = worker.COMPLETION_ACTIONS :: table

        -- A recurring schedule under the streak budget. consecutive_failures is
        -- the value claimed with the task; the worker counts the current run on
        -- top of it, so 0 here means "this is the first failure".
        local function recurring(overrides)
            local t = {
                schedule_type = "interval",
                retry_count = 0,
                max_retries = 3,
                consecutive_failures = 0,
                max_consecutive_failures = 7
            }
            for k, v in pairs(overrides or {}) do t[k] = v end
            return t
        end

        test.it("skips a non-retriable run instead of destroying the schedule", function()
            -- `retriable = false` says "retrying this run is pointless" -- which is
            -- true -- not "this schedule will never work again". A scope or
            -- binding that cannot resolve during a registry push resolves fine at
            -- the next occurrence.
            local action, reason = determine(
                recurring(),
                { error = "no agent configured", retriable = false }
            )
            test.eq(action, ACTIONS.SKIP)
            test.is_true(reason:find("no agent configured", 1, true) ~= nil,
                "reason must carry the error, got: " .. tostring(reason))
            test.is_true(reason:find("1/7", 1, true) ~= nil,
                "reason must show the streak against its budget, got: " .. tostring(reason))
        end)

        test.it("does not retry a non-retriable run", function()
            -- Skipping is not retrying: the budget the flag protects is untouched.
            for _, retries in ipairs({ 0, 1, 2 }) do
                local action = determine(
                    recurring({ retry_count = retries }),
                    { error = "boom", retriable = false }
                )
                test.eq(action, ACTIONS.SKIP, "retry_count=" .. retries)
            end
        end)

        test.it("gives up once the consecutive-failure budget is spent", function()
            -- Six previous failures plus this one is the seventh.
            local action, reason = determine(
                recurring({ consecutive_failures = 6 }),
                { error = "still broken", retriable = false }
            )
            test.eq(action, ACTIONS.DISABLE)
            test.is_true(reason:find("7 consecutive runs", 1, true) ~= nil,
                "reason must say the streak ran out, got: " .. tostring(reason))

            -- One occurrence earlier it is still only a skip.
            test.eq(determine(recurring({ consecutive_failures = 5 }),
                { error = "still broken", retriable = false }), ACTIONS.SKIP)
        end)

        test.it("honours a per-schedule budget", function()
            test.eq(determine(recurring({ consecutive_failures = 0, max_consecutive_failures = 1 }),
                { error = "boom", retriable = false }), ACTIONS.DISABLE,
                "a budget of 1 disables on the first failure")
            test.eq(determine(recurring({ consecutive_failures = 20, max_consecutive_failures = 100 }),
                { error = "boom", retriable = false }), ACTIONS.SKIP,
                "a generous budget keeps skipping")
        end)

        test.it("falls back to the default budget when the field is missing", function()
            local task = recurring()
            task.max_consecutive_failures = nil
            test.eq(determine(task, { error = "boom", retriable = false }), ACTIONS.SKIP)

            task.consecutive_failures = 6
            test.eq(determine(task, { error = "boom", retriable = false }), ACTIONS.DISABLE,
                "the default budget is 7")
        end)

        test.it("reports the error that started the streak, not just the latest", function()
            -- The row carries the streak origin. A retry that fails for a
            -- shallower reason must not be the only thing an operator sees.
            local action, reason = determine(
                recurring({ consecutive_failures = 2, last_error = "SharePoint 403" }),
                { error = "context canceled", retriable = false }
            )
            test.eq(action, ACTIONS.SKIP)
            test.is_true(reason:find("SharePoint 403", 1, true) ~= nil,
                "reason must carry the original cause, got: " .. tostring(reason))
            test.is_true(reason:find("context canceled", 1, true) ~= nil,
                "reason must carry the latest error too, got: " .. tostring(reason))
        end)

        test.it("does not repeat itself when the error has not changed", function()
            local _, reason = determine(
                recurring({ consecutive_failures = 2, last_error = "same" }),
                { error = "same", retriable = false }
            )
            local _, count = (reason :: string):gsub("same", "")
            test.eq(count, 1, "the error should appear once, got: " .. tostring(reason))
        end)

        test.it("finishes a successful once-schedule instead of disabling it", function()
            local action, reason = determine(
                { schedule_type = "once", retry_count = 0, max_retries = 0 },
                { error = nil }
            )
            test.eq(action, ACTIONS.COMPLETE)
            test.is_true(reason:find("completed successfully", 1, true) ~= nil,
                "reason must say it completed, got: " .. tostring(reason))
        end)

        test.it("fails a once-schedule and carries the error", function()
            local action, reason = determine(
                { schedule_type = "once", retry_count = 0, max_retries = 0 },
                { error = "no actor context", retriable = false }
            )
            test.eq(action, ACTIONS.FAIL)
            test.is_true(reason:find("no actor context", 1, true) ~= nil,
                "reason must carry the error, got: " .. tostring(reason))
        end)

        test.it("maps every terminal action to a terminal status", function()
            local terminal = worker.TERMINAL_STATUS :: table
            test.eq(terminal[ACTIONS.COMPLETE], "completed")
            test.eq(terminal[ACTIONS.FAIL], "failed")
            test.eq(terminal[ACTIONS.DISABLE], "disabled")
            -- Anything that keeps the schedule running must not be in the map.
            test.is_nil(terminal[ACTIONS.RESCHEDULE], "reschedule is not terminal")
            test.is_nil(terminal[ACTIONS.RETRY], "retry is not terminal")
        end)

        test.it("skips to the next run when this occurrence has spent its retries", function()
            local action, reason = determine(
                recurring({ retry_count = 3, max_retries = 3 }),
                { error = "downstream timeout", retriable = true }
            )
            test.eq(action, ACTIONS.SKIP)
            test.is_true(reason:find("downstream timeout", 1, true) ~= nil,
                "reason must carry the error, got: " .. tostring(reason))
            test.is_true(reason:find("Maximum retries", 1, true) ~= nil,
                "reason must still note the retry exhaustion")
        end)

        test.it("disables when both the retries and the streak are spent", function()
            local action, reason = determine(
                recurring({ retry_count = 3, max_retries = 3, consecutive_failures = 6 }),
                { error = "downstream timeout", retriable = true }
            )
            test.eq(action, ACTIONS.DISABLE)
            test.is_true(reason:find("Maximum retries", 1, true) ~= nil, tostring(reason))
            test.is_true(reason:find("consecutive", 1, true) ~= nil, tostring(reason))
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
                recurring({ retry_count = 1 }),
                { error = "transient", retriable = true }
            )
            test.eq(action, ACTIONS.RETRY)
        end)

        test.it("keeps skip out of the terminal map", function()
            -- A skip leaves the schedule running, so it must never be routed to
            -- retire_schedule.
            test.is_nil((worker.TERMINAL_STATUS :: table)[ACTIONS.SKIP])
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options)
    return run_cases(options)
end

return { run = run }
