local test = require("test")
local time = require("time")
local schedule_calculator = require("schedule_calculator")

local function define_tests()
    test.describe("Schedule Calculator", function()
        local test_base_time = time.now():utc()
        local future_time = test_base_time:add(2 * time.HOUR)
        local future_time_str = future_time:format(time.RFC3339)
        local past_time = test_base_time:add(-time.HOUR)
        local past_time_str = past_time:format(time.RFC3339)

        test.describe("Once Schedule", function()
            test.it("should return exact timestamp for future dates", function()
                local next_run, err = schedule_calculator.next_once_run(future_time_str, nil, nil)

                test.is_nil(err)
                test.not_nil(next_run)

                -- Verify it's a valid RFC3339 string
                local parsed, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)

                -- Should be the same time (within 1 second due to potential precision differences)
                test.is_true(math.abs(parsed:sub(future_time):seconds()) < 1)
            end)

            test.it("should return immediate execution for past timestamps", function()
                local before_call = time.now():utc()
                local next_run, err = schedule_calculator.next_once_run(past_time_str, nil, nil)
                local after_call = time.now():utc()

                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)

                -- Should be between before_call and after_call (immediate execution),
                -- with tolerance for execution time.
                test.is_true(parsed_time:after(before_call) or
                    math.abs(parsed_time:sub(before_call):seconds()) < 2)
                test.is_true(parsed_time:before(after_call) or
                    math.abs(parsed_time:sub(after_call):seconds()) < 2)
            end)

            test.it("should return nil if task already executed", function()
                local next_run, err = schedule_calculator.next_once_run(future_time_str, past_time_str, nil)

                test.is_nil(err)
                test.is_nil(next_run)
            end)

            test.it("should handle edge case timestamps", function()
                -- A plain future timestamp, far enough out to stay in the future.
                local next_run, err = schedule_calculator.next_once_run("2099-12-25T10:00:00Z", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                -- Leap year Feb 29 - should parse without error
                next_run, err = schedule_calculator.next_once_run("2024-02-29T12:00:00Z", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)
            end)

            test.it("should reject invalid timestamps", function()
                local invalid = {
                    "", "not-a-timestamp",
                    "2025-13-01T10:00:00Z", -- invalid month
                    "2025-02-30T10:00:00Z", -- invalid day
                    "2025-01-01T25:00:00Z", -- invalid hour
                    "2025-01-01T10:60:00Z", -- invalid minute
                    "2025-01-01T10:00:60Z", -- invalid second
                    "2023-02-29T10:00:00Z", -- Feb 29 in a non-leap year
                }

                local next_run, err = schedule_calculator.next_once_run(nil, nil, nil)
                test.is_nil(next_run, "nil expression must be rejected")
                test.not_nil(err, "nil expression must be rejected")

                for _, expression in ipairs(invalid) do
                    next_run, err = schedule_calculator.next_once_run(expression, nil, nil)
                    test.is_nil(next_run, "must reject: '" .. expression .. "'")
                    test.not_nil(err, "must reject: '" .. expression .. "'")
                end
            end)
        end)

        test.describe("Interval Schedule", function()
            test.it("should calculate exact intervals from last completion", function()
                local cases = {
                    { duration = "30m", seconds = 30 * 60 },
                    { duration = "1h", seconds = 60 * 60 },
                    { duration = "1h30m", seconds = 90 * 60 },
                    { duration = "45s", seconds = 45 },
                    { duration = "2h15m30s", seconds = 135 * 60 + 30 },
                }

                for _, case in ipairs(cases) do
                    local next_run, err = schedule_calculator.next_interval_run(case.duration, past_time_str, nil)
                    test.is_nil(err, case.duration)
                    test.not_nil(next_run, case.duration)

                    local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                    test.is_nil(parse_err, case.duration)

                    local diff = parsed_time:sub(past_time):seconds()
                    test.is_true(math.abs(diff - case.seconds) < 1,
                        case.duration .. " should land " .. case.seconds .. "s after the last run, got " .. tostring(diff))
                end
            end)

            test.it("should calculate first run from current time when no last_run_at", function()
                local before_call = time.now():utc()
                local next_run, err = schedule_calculator.next_interval_run("1h", nil, nil)
                local after_call = time.now():utc()

                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)

                -- Should be approximately 1 hour from now
                test.is_true(math.abs(parsed_time:sub(before_call):seconds() - 3600) < 5)
                test.is_true(math.abs(parsed_time:sub(after_call):seconds() - 3600) < 5)
            end)

            test.it("should handle very short and very long durations", function()
                -- Very short - 1s precision is fine for a seconds-resolution poller
                local next_run, err = schedule_calculator.next_interval_run("1s", past_time_str, nil)
                test.is_nil(err)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.is_true(math.abs(parsed_time:sub(past_time):seconds() - 1) < 1)

                -- Very long - just verify it works, don't check precise timing
                next_run, err = schedule_calculator.next_interval_run("24h", past_time_str, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.is_true(parsed_time:after(past_time))
            end)

            test.it("should reject invalid durations", function()
                -- The original listed nil first inside the table, so ipairs stopped
                -- immediately and this case asserted nothing at all.
                local next_run, err = schedule_calculator.next_interval_run(nil, nil, nil)
                test.is_nil(next_run, "nil duration must be rejected")
                test.not_nil(err, "nil duration must be rejected")

                -- "-1h" parses fine as a Go duration but has no next run; left
                -- unguarded it returned a next_run_at in the past, which the
                -- worker re-claimed on every poll forever.
                for _, invalid in ipairs({ "", "invalid", "1x", "1h1x", "-1h", "0s", "1h-30m" }) do
                    next_run, err = schedule_calculator.next_interval_run(invalid, nil, nil)
                    test.is_nil(next_run, "must reject duration: '" .. invalid .. "'")
                    test.not_nil(err, "must reject duration: '" .. invalid .. "'")
                end
            end)

            test.it("should reject invalid last_run_at timestamps", function()
                local next_run, err = schedule_calculator.next_interval_run("30m", "invalid-timestamp", nil)
                test.is_nil(next_run)
                test.not_nil(err)
                test.not_nil(err:match("Invalid last_run_at format"), "got: " .. tostring(err))
            end)
        end)

        test.describe("Ticker Schedule", function()
            test.it("should calculate fixed intervals advancing past times to future", function()
                -- Ticker should advance to the next valid time at or after now
                local next_run, err = schedule_calculator.next_ticker_run("15m", past_time_str, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)

                test.is_true(parsed_time:after(test_base_time) or parsed_time:equal(test_base_time))

                -- Should be a whole number of 15m steps from past_time
                local minutes = math.floor(parsed_time:sub(past_time):minutes() + 0.5)
                test.eq(minutes % 15, 0)
            end)

            test.it("should use creation time as base for first run", function()
                local creation_time = test_base_time:add(-2 * time.HOUR)
                local next_run, err = schedule_calculator.next_ticker_run(
                    "30m", nil, creation_time:format(time.RFC3339))
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)

                test.is_true(parsed_time:after(test_base_time) or parsed_time:equal(test_base_time))

                local minutes = math.floor(parsed_time:sub(creation_time):minutes() + 0.5)
                test.eq(minutes % 30, 0)
            end)

            test.it("should handle precise ticker intervals", function()
                local base_time = test_base_time:add(-2 * time.HOUR)

                local next_run, err = schedule_calculator.next_ticker_run(
                    "30m", base_time:format(time.RFC3339), nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)

                test.is_true(parsed_time:after(test_base_time) or parsed_time:equal(test_base_time))
                test.is_true(parsed_time:sub(test_base_time):hours() < 24)
            end)

            test.it("should reject invalid inputs", function()
                local next_run, err = schedule_calculator.next_ticker_run("invalid", nil, nil)
                test.is_nil(next_run, "invalid duration")
                test.not_nil(err, "invalid duration")

                next_run, err = schedule_calculator.next_ticker_run("30m", "invalid", nil)
                test.is_nil(next_run, "invalid last_run_at")
                test.not_nil(err, "invalid last_run_at")

                next_run, err = schedule_calculator.next_ticker_run("30m", nil, "invalid")
                test.is_nil(next_run, "invalid created_at")
                test.not_nil(err, "invalid created_at")

                -- A non-positive interval must be rejected, not walked. The
                -- catch-up loop advances by the interval until it reaches now, so
                -- a non-positive one never gets there and the call spins forever.
                --
                -- Probe the guard through next_interval_run first -- same guard,
                -- no loop. If the guard is ever removed this assertion fails
                -- cleanly instead of hanging the whole run on the calls below.
                local probe = schedule_calculator.next_interval_run("-1h", nil, nil)
                test.is_nil(probe,
                    "non-positive durations are not being rejected -- refusing to call next_ticker_run " ..
                    "with one, it would spin forever")

                for _, bad in ipairs({ "-1h", "0s", "-30m" }) do
                    next_run, err = schedule_calculator.next_ticker_run(bad, nil, nil)
                    test.is_nil(next_run, "must reject ticker interval: '" .. bad .. "'")
                    test.not_nil(err, "must reject ticker interval: '" .. bad .. "'")
                end
            end)
        end)

        test.describe("Cron Schedule", function()
            test.it("should calculate next run for simple expressions and verify timing", function()
                -- Every hour at minute 0
                local next_run, err = schedule_calculator.next_cron_run("0 * * * *", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.eq(parsed_time:minute(), 0)
                test.eq(parsed_time:second(), 0)

                -- The next top of the hour, so within an hour of now and in the future
                test.is_true(parsed_time:after(test_base_time))
                test.is_true(parsed_time:sub(test_base_time):hours() <= 1)
            end)

            test.it("should handle specific time expressions", function()
                -- Every day at 23:30
                local next_run, err = schedule_calculator.next_cron_run("30 23 * * *", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.eq(parsed_time:hour(), 23)
                test.eq(parsed_time:minute(), 30)
                test.eq(parsed_time:second(), 0)
                test.is_true(parsed_time:after(test_base_time))
            end)

            test.it("should handle weekday expressions correctly", function()
                -- Every Monday at 9 AM
                local next_run, err = schedule_calculator.next_cron_run("0 9 * * 1", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.eq(parsed_time:weekday(), 1) -- Monday
                test.eq(parsed_time:hour(), 9)
                test.eq(parsed_time:minute(), 0)
                test.is_true(parsed_time:after(test_base_time))
            end)

            test.it("should handle range expressions", function()
                -- Weekdays (Mon-Fri) at 9 AM
                local next_run, err = schedule_calculator.next_cron_run("0 9 * * 1-5", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)

                local weekday = parsed_time:weekday()
                test.is_true(weekday >= 1 and weekday <= 5, "got weekday " .. tostring(weekday))
                test.eq(parsed_time:hour(), 9)
                test.eq(parsed_time:minute(), 0)
            end)

            test.it("should handle step expressions precisely", function()
                -- Every 15 minutes
                local next_run, err = schedule_calculator.next_cron_run("*/15 * * * *", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.eq(parsed_time:minute() % 15, 0)
                test.eq(parsed_time:second(), 0)
                test.is_true(parsed_time:after(test_base_time))
            end)

            test.it("should handle complex multi-value expressions", function()
                local next_run, err = schedule_calculator.next_cron_run("15,30,45 * * * *", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)

                local minute = parsed_time:minute()
                test.is_true(minute == 15 or minute == 30 or minute == 45, "got minute " .. tostring(minute))
                test.eq(parsed_time:second(), 0)
            end)

            test.it("should handle Sunday as both 0 and 7", function()
                local next_run, err = schedule_calculator.next_cron_run("0 9 * * 0", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.eq(parsed_time:weekday(), 0) -- Sunday

                -- 7 must normalise to the same day as 0
                next_run, err = schedule_calculator.next_cron_run("0 9 * * 7", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.eq(parsed_time:weekday(), 0)
            end)

            test.it("should handle edge case cron expressions", function()
                -- A day-of-month range
                local next_run, err = schedule_calculator.next_cron_run("0 0 28-31 * *", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.is_true(parsed_time:day() >= 28, "got day " .. tostring(parsed_time:day()))

                -- End of year
                next_run, err = schedule_calculator.next_cron_run("59 23 31 12 *", nil, nil)
                test.is_nil(err)
                test.not_nil(next_run)

                parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.eq(parsed_time:month(), 12)
                test.eq(parsed_time:day(), 31)
                test.eq(parsed_time:hour(), 23)
                test.eq(parsed_time:minute(), 59)
            end)

            test.it("should reject invalid cron expressions with detailed validation", function()
                local invalid = {
                    "too few fields",
                    "* * * *",     -- missing field
                    "60 * * * *",  -- invalid minute
                    "* 25 * * *",  -- invalid hour
                    "* * 32 * *",  -- invalid day
                    "* * * 13 *",  -- invalid month
                    "* * * * 8",   -- invalid weekday
                    "",
                }

                local next_run, err = schedule_calculator.next_cron_run(nil, nil, nil)
                test.is_nil(next_run, "nil expression must be rejected")
                test.not_nil(err, "nil expression must be rejected")

                for _, expression in ipairs(invalid) do
                    next_run, err = schedule_calculator.next_cron_run(expression, nil, nil)
                    test.is_nil(next_run, "must reject cron: '" .. expression .. "'")
                    test.not_nil(err, "must reject cron: '" .. expression .. "'")
                end
            end)

            test.it("should handle last_run_at parameter correctly", function()
                -- A last_run_at in the future is the base, not the current time
                local future_base = test_base_time:add(3 * time.HOUR)

                local next_run, err = schedule_calculator.next_cron_run(
                    "0 * * * *", future_base:format(time.RFC3339), nil)
                test.is_nil(err)
                test.not_nil(next_run)

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.is_true(parsed_time:after(future_base))
            end)

            test.it("should handle complex expressions without infinite loops", function()
                -- Feb 29 only exists in leap years, so this either finds a date or
                -- gives up cleanly within the iteration limit -- it must not hang.
                local next_run, err = schedule_calculator.next_cron_run("0 0 29 2 *", nil, nil)

                if next_run then
                    test.is_nil(err)
                    local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                    test.is_nil(parse_err)
                    test.eq(parsed_time:month(), 2)
                    test.eq(parsed_time:day(), 29)

                    local year = parsed_time:year()
                    test.is_true((year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0),
                        tostring(year) .. " is not a leap year")
                else
                    test.not_nil(err)
                    test.not_nil(err:match("Could not find next cron time"), "got: " .. tostring(err))
                end
            end)
        end)

        test.describe("Return Format Validation", function()
            test.it("should always return RFC3339 formatted strings", function()
                local cases = {
                    { name = "once", result = schedule_calculator.next_once_run(future_time_str, nil, nil) },
                    { name = "interval", result = schedule_calculator.next_interval_run("30m", nil, nil) },
                    { name = "ticker", result = schedule_calculator.next_ticker_run("15m", nil, nil) },
                    { name = "cron", result = schedule_calculator.next_cron_run("0 * * * *", nil, nil) },
                }

                for _, case in ipairs(cases) do
                    test.not_nil(case.result, case.name)
                    test.eq(type(case.result), "string", case.name)

                    local parsed, parse_err = time.parse(time.RFC3339, case.result)
                    test.is_nil(parse_err, case.name)
                    test.not_nil(parsed, case.name)

                    -- Re-formatting must produce the identical string
                    test.eq(case.result, parsed:format(time.RFC3339), case.name)
                end
            end)

            test.it("should return consistent time zones (UTC)", function()
                local results = {
                    once = schedule_calculator.next_once_run(future_time_str, nil, nil),
                    interval = schedule_calculator.next_interval_run("1h", nil, nil),
                    ticker = schedule_calculator.next_ticker_run("1h", nil, nil),
                    cron = schedule_calculator.next_cron_run("0 * * * *", nil, nil),
                }

                for name, result in pairs(results) do
                    test.not_nil(result, name)
                    test.not_nil(result:match("Z$") or result:match("[+-]%d%d:%d%d$"),
                        name .. " must carry a zone: " .. tostring(result))

                    local parsed = time.parse(time.RFC3339, result)
                    test.eq(parsed:location():string(), "UTC", name)
                end
            end)
        end)

        test.describe("Error Handling and Edge Cases", function()
            test.it("should handle all null/empty input combinations", function()
                local methods = {
                    { name = "once", method = schedule_calculator.next_once_run },
                    { name = "interval", method = schedule_calculator.next_interval_run },
                    { name = "ticker", method = schedule_calculator.next_ticker_run },
                    { name = "cron", method = schedule_calculator.next_cron_run },
                }

                for _, info in ipairs(methods) do
                    local result, err = info.method(nil, nil, nil)
                    test.is_nil(result, info.name .. " with nil expression")
                    test.not_nil(err, info.name .. " with nil expression")

                    result, err = info.method("", nil, nil)
                    test.is_nil(result, info.name .. " with empty expression")
                    test.not_nil(err, info.name .. " with empty expression")
                end
            end)

            test.it("should handle very large time differences", function()
                -- Very far future - returned verbatim
                local far_future = "2099-12-31T23:59:59Z"
                local next_run, err = schedule_calculator.next_once_run(far_future, nil, nil)
                test.is_nil(err)
                test.eq(next_run, far_future)

                -- Very far past - collapses to immediate execution
                local before = time.now():utc()
                local next_run2, err2 = schedule_calculator.next_once_run("1970-01-01T00:00:00Z", nil, nil)
                test.is_nil(err2)
                test.not_nil(next_run2)

                -- RFC3339 carries no sub-second precision, so "now" formats to
                -- just under the moment of the call. The original asserted a
                -- strict ordering against a base captured earlier in the suite,
                -- which made it fail or pass on sub-second luck; allow a second
                -- of slack, as the other immediate-execution case here does.
                local parsed = time.parse(time.RFC3339, next_run2)
                test.is_true(math.abs(parsed:sub(before):seconds()) < 2,
                    "a past `once` timestamp must collapse to roughly now, got " .. tostring(next_run2))
            end)

            test.it("should handle boundary month transitions", function()
                -- A 2h interval from 31 Jan 23:00 must land on 1 Feb 01:00
                local next_run, err = schedule_calculator.next_interval_run("2h", "2025-01-31T23:00:00Z", nil)
                test.is_nil(err)

                local parsed, parse_err = time.parse(time.RFC3339, next_run)
                test.is_nil(parse_err)
                test.eq(parsed:month(), 2)
                test.eq(parsed:day(), 1)
                test.eq(parsed:hour(), 1)
            end)

            test.it("should handle performance limits for complex cron", function()
                local start_time = time.now():utc()
                local next_run, err = schedule_calculator.next_cron_run("*/5 9-17 * * 1-5", nil, nil)
                local end_time = time.now():utc()

                test.is_nil(err)
                test.not_nil(next_run)
                test.is_true(end_time:sub(start_time):seconds() < 2, "a realistic expression must resolve fast")

                -- An expression that may have no nearby match must still give up quickly
                start_time = time.now():utc()
                schedule_calculator.next_cron_run("0 0 29 2 *", nil, nil)
                end_time = time.now():utc()
                test.is_true(end_time:sub(start_time):seconds() < 5, "search must be bounded, not hang")
            end)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
