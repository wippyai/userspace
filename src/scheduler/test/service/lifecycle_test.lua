local test = require("test")
local time = require("time")
local sql = require("sql")
local schedule_repo = require("schedule_repo")
local schedule_calculator = require("schedule_calculator")
local worker = require("worker")

local A = worker.COMPLETION_ACTIONS

local determine = worker.determine_completion_action ::
    (task: table, exec_result: table) -> (string, string?)

local function reset()
    local db, err = sql.get("app:db")
    if err then error(err) end
    db:execute("DELETE FROM schedules")
    db:release()
end

local function run_until_disabled(opts)
    local id, err = schedule_repo.create({
        class = "user",
        user_id = "user-1",
        task_implementation_id = "app:fixture_binding",
        schedule_type = schedule_repo.SCHEDULE_TYPES.INTERVAL,
        schedule_expression = "1s",
        next_run_at = time.now():utc(),
        max_retries = opts.max_retries,
        max_consecutive_failures = opts.budget,
    })
    if err then error(err) end

    local occurrences, attempts = 1, 0
    for _ = 1, 500 do
        -- The worker decides from the row as it was claimed, not as it is now.
        local task = schedule_repo.get(id)
        if not task then
            error("the schedule disappeared mid-run")
        end
        attempts = attempts + 1
        schedule_repo.update_execution_result(id, false, "boom")

        local action = determine(task, { error = "boom", retriable = opts.retriable })

        if action == A.DISABLE then
            return occurrences, attempts
        elseif action == A.SKIP then
            occurrences = occurrences + 1
            schedule_repo.reschedule_task(id, schedule_calculator, { after_failure = true })
        elseif action == A.RETRY then
            schedule_repo.reset_for_retry(id)
        else
            error("unexpected action: " .. tostring(action))
        end
    end
    error("the schedule was never disabled")
end

local function define_tests()
    test.describe("how long a broken schedule survives", function()
        test.before_each(reset)

        test.it("gets its whole budget of runs whatever max_retries is", function()
            -- max_retries and max_consecutive_failures must be independent: one
            -- bounds attempts inside a run, the other bounds runs. They used to
            -- multiply, so raising max_retries silently shortened the schedule's
            -- life -- reply drafting, at max_retries=5, died after two runs.
            for _, case in ipairs({
                { max_retries = 0, retriable = false, label = "non-retriable" },
                { max_retries = 1, retriable = true, label = "max_retries=1" },
                { max_retries = 5, retriable = true, label = "max_retries=5" },
                { max_retries = 20, retriable = true, label = "max_retries=20" },
            }) do
                local occurrences = run_until_disabled({
                    max_retries = case.max_retries,
                    retriable = case.retriable,
                    budget = 7,
                })
                test.eq(occurrences, 7,
                    case.label .. ": a budget of 7 must be 7 runs, got " .. occurrences)
                reset()
            end
        end)

        test.it("honours a smaller budget", function()
            test.eq((run_until_disabled({ max_retries = 3, retriable = true, budget = 1 })), 1)
            reset()
            test.eq((run_until_disabled({ max_retries = 3, retriable = true, budget = 3 })), 3)
        end)

        test.it("spends the retry budget inside each run", function()
            local occurrences, attempts = run_until_disabled({
                max_retries = 2, retriable = true, budget = 4,
            })
            test.eq(occurrences, 4)
            -- 3 attempts per run: the first plus two retries.
            test.eq(attempts, 12, "each run must still get all its retries")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
