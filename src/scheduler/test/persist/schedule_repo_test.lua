local test = require("test")
local sql = require("sql")
local time = require("time")
local schedule_repo = require("schedule_repo")
local schedule_calculator = require("schedule_calculator")

local HOUR = 3600
local DAY = 24 * HOUR

local DB = "app:db"

local COMPLETED_WINDOW = 24  -- hours
local FAILED_WINDOW = 72     -- hours
local DISABLED_WINDOW = 168  -- hours (7 days)

local function db_handle()
    local db, err = sql.get(DB)
    if err then
        error("failed to connect to " .. DB .. ": " .. err)
    end
    return db
end

local function db_stamp(db_type, when)
    if db_type == sql.type.SQLITE then
        return when:unix()
    end
    return when:format(time.RFC3339)
end

local function reset()
    local db = db_handle()
    db:execute("DELETE FROM schedules")
    db:release()
end

local function age(id, seconds)
    local db = db_handle()
    local db_type = db:type()
    local _, err = sql.builder.update("schedules")
        :set("updated_at", db_stamp(db_type, time.now():utc():add(-seconds * time.SECOND)))
        :where("id = ?", id)
        :run_with(db)
        :exec()
    db:release()
    if err then
        error("failed to age fixture: " .. err)
    end
end

local function terminal_statuses()
    local set = schedule_repo.TERMINAL_STATUSES
    if type(set) ~= "table" or type(schedule_repo.retire_schedule) ~= "function" then
        error("schedule_repo.retire_schedule/TERMINAL_STATUSES are missing -- a finished one-off " ..
            "lands in `disabled` again, indistinguishable from a schedule the scheduler gave up on, " ..
            "and the completed/failed retention windows have nothing to match")
    end
    return set
end

local function fixture(class, status, age_seconds)
    local id, err = schedule_repo.create({
        description = "retention fixture",
        class = class,
        user_id = "user-1",
        task_implementation_id = "app:fixture_binding",
        schedule_type = schedule_repo.SCHEDULE_TYPES.CRON,
        schedule_expression = "0 * * * *",
        next_run_at = time.now():utc(),
    })
    if err then
        error("failed to create fixture: " .. err)
    end

    -- Exactly what the worker calls when it takes a schedule out of rotation.
    -- A non-terminal fixture is left as created, which is already 'scheduled'.
    if terminal_statuses()[status] then
        local ok, rerr = schedule_repo.retire_schedule(id, status, "retention fixture")
        if not ok then
            error("failed to retire fixture: " .. tostring(rerr))
        end
    end

    -- After the status write, which stamps updated_at = now.
    age(id, age_seconds)
    return id
end

local function alive(id)
    local row = schedule_repo.get(id)
    return row ~= nil
end

local function cutoff(now, hours)
    if type(schedule_repo.retention_cutoff) ~= "function" then
        error("schedule_repo.retention_cutoff is missing -- the retention fix has been REVERTED; " ..
            "windows are back to milliseconds and every terminal schedule is hard-deleted on sight")
    end
    return schedule_repo.retention_cutoff(now, hours)
end

local function define_tests()
    test.describe("retention_cutoff", function()
        test.it("converts hours, not milliseconds", function()
            local now = time.now():utc()

            for _, hours in ipairs({ COMPLETED_WINDOW, FAILED_WINDOW, DISABLED_WINDOW }) do
                local seconds = now:sub(cutoff(now, hours)):seconds()
                local want = hours * HOUR
                test.is_true(math.abs(seconds - want) < 1,
                    hours .. "h should put the cutoff " .. want .. "s before now, got " ..
                    tostring(seconds) .. "s -- retention is being computed in the wrong unit")
            end
        end)

        test.it("puts the cutoff in the past", function()
            local now = time.now():utc()
            -- A sign error here would reap every terminal schedule on sight.
            test.is_true(now:sub(cutoff(now, 24)):seconds() > 0, "the cutoff must be earlier than now")
        end)

        test.it("treats a zero or missing window as now", function()
            local now = time.now():utc()
            test.is_true(math.abs(now:sub(cutoff(now, 0)):seconds()) < 1)
            test.is_true(math.abs(now:sub(cutoff(now, nil)):seconds()) < 1)
        end)
    end)

    test.describe("retire_schedule", function()
        test.before_each(reset)

        test.it("records the status and the reason, and stops the schedule", function()
            for status in pairs(terminal_statuses()) do
                local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
                local ok, err = schedule_repo.retire_schedule(id, status, "because " .. status)
                test.is_true(ok, status)
                test.is_nil(err, status)

                local row = schedule_repo.get(id)
                test.eq(row.status, status)
                test.is_false(row.enabled, status .. " must not stay enabled")
                test.is_false(row.picked, status .. " must release the claim")
                if status == schedule_repo.STATUS.COMPLETED then
                    test.is_nil(row.last_error, "a completed schedule has no error to record")
                else
                    test.eq(row.last_error, "because " .. status)
                end
            end
        end)

        test.it("refuses a status that is not terminal", function()
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)

            for _, bad in ipairs({ "scheduled", "executing", "", "nonsense" }) do
                local ok, err = schedule_repo.retire_schedule(id, bad, "x")
                test.is_false(ok, "must refuse status '" .. bad .. "'")
                test.not_nil(err, "must refuse status '" .. bad .. "'")
            end

            local ok, err = schedule_repo.retire_schedule(id, nil, "x")
            test.is_false(ok, "must refuse a missing status")
            test.not_nil(err, "must refuse a missing status")

            -- Refused writes leave the row exactly as it was.
            test.eq(schedule_repo.get(id).status, schedule_repo.STATUS.SCHEDULED)
        end)

        test.it("leaves disable_schedule behaving exactly as before", function()
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
            test.is_true(schedule_repo.disable_schedule(id, "gave up"))

            local row = schedule_repo.get(id)
            test.eq(row.status, schedule_repo.STATUS.DISABLED)
            test.is_false(row.enabled)
            test.eq(row.last_error, "gave up")
        end)

        test.it("comes back into rotation when the revival is written", function()
            -- The round trip the UI toggle performs. Writing `enabled` alone is
            -- what left a row reading as ON that could never run; the repo has
            -- always been able to write `status`, the binding just never did.
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
            schedule_repo.update_execution_result(id, false, "SharePoint 403")
            test.is_true(schedule_repo.retire_schedule(id, schedule_repo.STATUS.DISABLED, "gave up"))

            -- Enabled alone: still dead.
            test.is_true(schedule_repo.update(id, { enabled = true }))
            local claimed = schedule_repo.claim_ready_tasks("test-worker", 10)
            for _, row in ipairs(claimed or {}) do
                test.is_true(row.id ~= id, "enabled alone must not be enough to run again")
            end
            test.eq(schedule_repo.get(id).status, schedule_repo.STATUS.DISABLED)

            -- With the revival fields, it runs again and starts from a clean streak.
            test.is_true(schedule_repo.update(id, {
                enabled = true,
                status = schedule_repo.STATUS.SCHEDULED,
                retry_count = 0,
                consecutive_failures = 0
            }))

            local row = schedule_repo.get(id)
            test.eq(row.status, schedule_repo.STATUS.SCHEDULED)
            test.eq(row.consecutive_failures, 0, "a revived schedule must not inherit the streak that killed it")
            test.eq(row.retry_count, 0)

            local seen = false
            for _, claimed_row in ipairs(schedule_repo.claim_ready_tasks("test-worker", 10) or {}) do
                if claimed_row.id == id then seen = true end
            end
            test.is_true(seen, "a revived schedule must be claimable again")
        end)

        test.it("a retired schedule is never claimed again", function()
            -- The whole point of a terminal status. claim_ready_tasks only takes
            -- status='scheduled', so each of the three must drop out of rotation.
            local live = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
            local completed = fixture("user", schedule_repo.STATUS.COMPLETED, 0)
            local failed = fixture("user", schedule_repo.STATUS.FAILED, 0)
            local disabled = fixture("user", schedule_repo.STATUS.DISABLED, 0)

            local claimed, err = schedule_repo.claim_ready_tasks("test-worker", 10)
            test.is_nil(err)

            local seen = {}
            for _, row in ipairs(claimed or {}) do
                seen[row.id] = true
            end

            test.is_true(seen[live], "a due schedule must still be claimed")
            test.is_nil(seen[completed], "a completed schedule must never run again")
            test.is_nil(seen[failed], "a failed schedule must never run again")
            test.is_nil(seen[disabled], "a disabled schedule must never run again")
        end)
    end)

    test.describe("failure bookkeeping", function()
        test.before_each(reset)

        test.it("keeps the error that started the streak", function()
            -- A retry seconds later usually fails for a shallower reason. Plain
            -- assignment left only that, so the real cause was overwritten by the
            -- last attempt.
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)

            schedule_repo.update_execution_result(id, false, "SharePoint 403")
            test.eq(schedule_repo.get(id).last_error, "SharePoint 403")

            schedule_repo.update_execution_result(id, false, "context canceled")
            test.eq(schedule_repo.get(id).last_error, "SharePoint 403",
                "the second failure must not overwrite the cause of the first")

            local row = schedule_repo.get(id)
            test.eq(row.retry_count, 2, "both attempts must be counted")
            test.eq(row.consecutive_failures, 0,
                "retries within one occurrence must not spend the streak budget")
        end)

        test.it("starts a new streak after a success", function()
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)

            schedule_repo.update_execution_result(id, false, "first cause")
            schedule_repo.update_execution_result(id, true, nil)

            local ok = schedule_repo.get(id)
            test.is_nil(ok.last_error, "success clears the error")
            test.eq(ok.consecutive_failures, 0)

            schedule_repo.update_execution_result(id, false, "second cause")
            test.eq(schedule_repo.get(id).last_error, "second cause",
                "a fresh streak records its own cause")
        end)

        test.it("skipping a failed occurrence keeps the streak and the cause", function()
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
            schedule_repo.update_execution_result(id, false, "SharePoint 403")

            local ok, err = schedule_repo.reschedule_task(id, schedule_calculator, { after_failure = true })
            test.is_true(ok, tostring(err))

            local row = schedule_repo.get(id)
            test.eq(row.status, schedule_repo.STATUS.SCHEDULED, "the schedule keeps running")
            test.eq(row.consecutive_failures, 1, "the streak must survive a skip, or the budget never runs out")
            test.eq(row.last_error, "SharePoint 403", "the cause must survive a skip")
            test.eq(row.retry_count, 0, "a new occurrence gets a fresh retry budget")
        end)

        test.it("a skip moves the schedule into the future, it does not respin it", function()
            -- reset_for_retry leaves next_run_at alone, so a retry is re-claimed on
            -- the next poll. A skip must not behave that way, or a permanently
            -- broken schedule would run flat out until its budget burned down.
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
            schedule_repo.update_execution_result(id, false, "boom")

            test.is_true(schedule_repo.reschedule_task(id, schedule_calculator, { after_failure = true }))

            local claimed = schedule_repo.claim_ready_tasks("test-worker", 10)
            for _, row in ipairs(claimed or {}) do
                test.is_true(row.id ~= id, "a skipped occurrence must not be immediately claimable again")
            end

            local next_run = time.parse(time.RFC3339, schedule_repo.get(id).next_run_at :: string)
            test.is_true(next_run:after(time.now():utc()), "next_run_at must be in the future")
        end)

        test.it("the streak counts occurrences, whatever they cost in retries", function()
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)

            for _ = 1, 6 do
                schedule_repo.update_execution_result(id, false, "boom")
            end
            test.eq(schedule_repo.get(id).consecutive_failures, 0, "six attempts, occurrence not over")

            schedule_repo.reschedule_task(id, schedule_calculator, { after_failure = true })
            test.eq(schedule_repo.get(id).consecutive_failures, 1, "six attempts are still one failed occurrence")

            schedule_repo.update_execution_result(id, false, "boom")
            schedule_repo.reschedule_task(id, schedule_calculator, { after_failure = true })
            test.eq(schedule_repo.get(id).consecutive_failures, 2)
        end)

        test.it("a plain reschedule still clears the streak", function()
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
            schedule_repo.update_execution_result(id, false, "SharePoint 403")

            test.is_true(schedule_repo.reschedule_task(id, schedule_calculator))

            local row = schedule_repo.get(id)
            test.eq(row.consecutive_failures, 0)
            test.is_nil(row.last_error)
        end)

        test.it("defaults the consecutive-failure budget and lets it be set", function()
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
            test.eq(schedule_repo.get(id).max_consecutive_failures,
                schedule_repo.DEFAULT_MAX_CONSECUTIVE_FAILURES)
            test.eq(schedule_repo.DEFAULT_MAX_CONSECUTIVE_FAILURES, 7)

            local custom, err = schedule_repo.create({
                class = "user",
                user_id = "user-1",
                task_implementation_id = "app:fixture_binding",
                schedule_type = schedule_repo.SCHEDULE_TYPES.CRON,
                schedule_expression = "0 * * * *",
                next_run_at = time.now():utc(),
                max_consecutive_failures = 2,
            })
            test.is_nil(err)
            test.eq(schedule_repo.get(custom).max_consecutive_failures, 2)
        end)

        test.it("a finished one-off records no error", function()
            local id = fixture("user", schedule_repo.STATUS.SCHEDULED, 0)
            test.is_true(schedule_repo.retire_schedule(id, schedule_repo.STATUS.COMPLETED,
                "Once schedule completed successfully"))

            local row = schedule_repo.get(id)
            test.eq(row.status, schedule_repo.STATUS.COMPLETED)
            test.is_nil(row.last_error, "last_error is for errors, not for a success sentence")
        end)
    end)

    test.describe("Cleanup retention windows", function()
        test.before_each(reset)

        test.it("reaps a disabled schedule past the window and leaves a fresher one", function()
            local stale = fixture("user", schedule_repo.STATUS.DISABLED, 8 * DAY)
            local fresh = fixture("user", schedule_repo.STATUS.DISABLED, 1 * HOUR)

            local deleted, err = schedule_repo.cleanup_disabled_schedules(DISABLED_WINDOW)
            test.is_nil(err)

            test.is_false(alive(stale), "an 8-day-old disabled schedule is past a 7-day window and must be reaped")
            test.is_true(alive(fresh),
                "a schedule disabled an hour ago is inside a 7-day window and must survive -- " ..
                "if it is gone, retention is being computed in milliseconds again")
            test.eq(deleted, 1)
        end)

        test.it("reaps user and system schedules on the same terms", function()
            -- Retention is a time policy, not an access policy. Filtering the
            -- DELETEs by class was considered and rejected: it leaks every
            -- abandoned user schedule forever and stops cleaning up finished
            -- one-offs, which are class='user' too. The window is what protects a
            -- schedule, and the window is what was broken.
            local stale_user = fixture("user", schedule_repo.STATUS.DISABLED, 30 * DAY)
            local stale_system = fixture("system", schedule_repo.STATUS.DISABLED, 30 * DAY)
            local fresh_user = fixture("user", schedule_repo.STATUS.DISABLED, 1 * HOUR)
            local fresh_system = fixture("system", schedule_repo.STATUS.DISABLED, 1 * HOUR)

            local deleted, err = schedule_repo.cleanup_disabled_schedules(DISABLED_WINDOW)
            test.is_nil(err)

            test.is_false(alive(stale_user), "a user schedule past the window is reaped like any other")
            test.is_false(alive(stale_system), "a system schedule past the window is reaped")
            test.is_true(alive(fresh_user), "a user schedule inside the window survives")
            test.is_true(alive(fresh_system), "a system schedule inside the window survives")
            test.eq(deleted, 2)
        end)

        test.it("keeps completed for 24h and failed for 72h as separate windows", function()
            local completed_stale = fixture("user", schedule_repo.STATUS.COMPLETED, 25 * HOUR)
            local completed_fresh = fixture("user", schedule_repo.STATUS.COMPLETED, 1 * HOUR)
            -- 25h is past the completed window but well inside the failed one, so
            -- this row only survives if the two windows are actually distinct.
            local failed_fresh = fixture("system", schedule_repo.STATUS.FAILED, 25 * HOUR)
            local failed_stale = fixture("system", schedule_repo.STATUS.FAILED, 73 * HOUR)

            local deleted, err = schedule_repo.cleanup_old_tasks(COMPLETED_WINDOW, FAILED_WINDOW)
            test.is_nil(err)

            test.is_false(alive(completed_stale), "completed past 24h must be reaped")
            test.is_true(alive(completed_fresh), "completed an hour ago must survive")
            test.is_true(alive(failed_fresh), "failed 25h ago is inside the 72h window and must survive")
            test.is_false(alive(failed_stale), "failed past 72h must be reaped")
            test.eq(deleted, 2)
        end)

        test.it("reaps a finished one-off on the completed window, not the disabled one", function()
            local done = fixture("user", schedule_repo.STATUS.COMPLETED, 25 * HOUR)

            test.eq(schedule_repo.cleanup_disabled_schedules(DISABLED_WINDOW), 0,
                "a finished one-off is not disabled and must not be reaped as one")
            test.is_true(alive(done))

            test.eq(schedule_repo.cleanup_old_tasks(COMPLETED_WINDOW, FAILED_WINDOW), 1)
            test.is_false(alive(done), "25h is past the 24h completed window")
        end)

        test.it("leaves a live schedule alone whatever its age", function()
            local live = fixture("system", schedule_repo.STATUS.SCHEDULED, 30 * DAY)

            schedule_repo.cleanup_disabled_schedules(DISABLED_WINDOW)
            schedule_repo.cleanup_old_tasks(COMPLETED_WINDOW, FAILED_WINDOW)

            test.is_true(alive(live), "cleanup must only ever touch terminal statuses")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
