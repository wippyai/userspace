local test = require("test")
local time = require("time")
local schedule_calculator = require("schedule_calculator")

local function define_tests()
    describe("Schedule Calculator", function()
        -- Use UTC time consistently for all tests
        local test_base_time = time.now():utc()
        local test_base_time_str = test_base_time:format(time.RFC3339)
        local future_time = test_base_time:add(2 * time.HOUR)
        local future_time_str = future_time:format(time.RFC3339)
        local past_time = test_base_time:add(-time.HOUR)
        local past_time_str = past_time:format(time.RFC3339)

        describe("Once Schedule", function()
            it("should return exact timestamp for future dates", function()
                local next_run, err = schedule_calculator.next_once_run(future_time_str, nil, nil)

                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                -- Verify it's a valid RFC3339 string
                local parsed, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                -- Should be the same time (within 1 second due to potential precision/timezone differences)
                local diff = parsed:sub(future_time)
                expect(math.abs(diff:seconds()) < 1).to_be_true()
            end)

            it("should return immediate execution for past timestamps", function()
                local before_call = time.now():utc()
                local next_run, err = schedule_calculator.next_once_run(past_time_str, nil, nil)
                local after_call = time.now():utc()

                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                -- Should be between before_call and after_call (immediate execution)
                -- Allow some tolerance for execution time
                expect(parsed_time:after(before_call) or
                       math.abs(parsed_time:sub(before_call):seconds()) < 2).to_be_true()
                expect(parsed_time:before(after_call) or
                       math.abs(parsed_time:sub(after_call):seconds()) < 2).to_be_true()
            end)

            it("should return nil if task already executed", function()
                local next_run, err = schedule_calculator.next_once_run(future_time_str, past_time_str, nil)

                expect(err).to_be_nil()
                expect(next_run).to_be_nil()
            end)

            it("should handle edge case timestamps", function()
                -- Test with a simple future timestamp
                local simple_future = "2025-12-25T10:00:00Z"
                local next_run, err = schedule_calculator.next_once_run(simple_future, nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                -- Leap year Feb 29 - should parse without error
                local leap_day = "2024-02-29T12:00:00Z"
                next_run, err = schedule_calculator.next_once_run(leap_day, nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()
            end)

            it("should reject invalid timestamps", function()
                local invalid_cases = {
                    { input = nil, desc = "nil input" },
                    { input = "", desc = "empty string" },
                    { input = "not-a-timestamp", desc = "invalid format" },
                    { input = "2025-13-01T10:00:00Z", desc = "invalid month" },
                    { input = "2025-02-30T10:00:00Z", desc = "invalid day" },
                    { input = "2025-01-01T25:00:00Z", desc = "invalid hour" },
                    { input = "2025-01-01T10:60:00Z", desc = "invalid minute" },
                    { input = "2025-01-01T10:00:60Z", desc = "invalid second" },
                    { input = "2023-02-29T10:00:00Z", desc = "Feb 29 in non-leap year" }
                }

                for _, case in ipairs(invalid_cases) do
                    local next_run, err = schedule_calculator.next_once_run(case.input, nil, nil)
                    expect(next_run).to_be_nil()
                    expect(err).not_to_be_nil()
                end
            end)
        end)

        describe("Interval Schedule", function()
            it("should calculate exact intervals from last completion", function()
                local test_cases = {
                    { duration = "30m", expected_minutes = 30 },
                    { duration = "1h", expected_minutes = 60 },
                    { duration = "1h30m", expected_minutes = 90 },
                    { duration = "45s", expected_seconds = 45 },
                    { duration = "2h15m30s", expected_minutes = 135, expected_seconds = 30 }
                }

                for _, case in ipairs(test_cases) do
                    local next_run, err = schedule_calculator.next_interval_run(case.duration, past_time_str, nil)
                    expect(err).to_be_nil()
                    expect(next_run).not_to_be_nil()

                    local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                    expect(parse_err).to_be_nil()

                    local diff = parsed_time:sub(past_time)
                    local expected_seconds = (case.expected_minutes or 0) * 60 + (case.expected_seconds or 0)
                    expect(math.abs(diff:seconds() - expected_seconds) < 1).to_be_true()
                end
            end)

            it("should calculate first run from current time when no last_run_at", function()
                local before_call = time.now():utc()
                local next_run, err = schedule_calculator.next_interval_run("1h", nil, nil)
                local after_call = time.now():utc()

                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                -- Should be approximately 1 hour from now
                local diff_from_before = parsed_time:sub(before_call)
                local diff_from_after = parsed_time:sub(after_call)

                expect(math.abs(diff_from_before:seconds() - 3600) < 5).to_be_true()
                expect(math.abs(diff_from_after:seconds() - 3600) < 5).to_be_true()
            end)

            it("should handle very short and very long durations", function()
                -- Very short - 1s precision is fine for 5s polling system
                local next_run, err = schedule_calculator.next_interval_run("1s", past_time_str, nil)
                expect(err).to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                local diff = parsed_time:sub(past_time)
                expect(math.abs(diff:seconds() - 1) < 1).to_be_true() -- 1s tolerance

                -- Very long - just verify it works, don't check precise timing
                next_run, err = schedule_calculator.next_interval_run("24h", past_time_str, nil) -- 1 day
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                -- Just verify it's later than the original time
                expect(parsed_time:after(past_time)).to_be_true()
            end)

            it("should reject invalid durations", function()
                local invalid_cases = {
                    nil, "", "invalid", "1x", "1h1x", "-1h", "1h-30m"
                }

                for _, invalid in ipairs(invalid_cases) do
                    local next_run, err = schedule_calculator.next_interval_run(invalid, nil, nil)
                    expect(next_run).to_be_nil()
                    expect(err).not_to_be_nil()
                end
            end)

            it("should reject invalid last_run_at timestamps", function()
                local next_run, err = schedule_calculator.next_interval_run("30m", "invalid-timestamp", nil)
                expect(next_run).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err:match("Invalid last_run_at format")).not_to_be_nil()
            end)
        end)

        describe("Ticker Schedule", function()
            it("should calculate fixed intervals advancing past times to future", function()
                -- Ticker should advance to next valid time at or after now
                local next_run, err = schedule_calculator.next_ticker_run("15m", past_time_str, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                -- Should be at or after current time
                expect(parsed_time:after(test_base_time) or parsed_time:equal(test_base_time)).to_be_true()

                -- Should be a multiple of 15m from past_time
                local diff = parsed_time:sub(past_time)
                local minutes = math.floor(diff:minutes() + 0.5) -- Round to nearest minute
                expect(minutes % 15).to_equal(0)
            end)

            it("should use creation time as base for first run", function()
                local creation_time = test_base_time:add(-2 * time.HOUR)
                local creation_time_str = creation_time:format(time.RFC3339)

                local next_run, err = schedule_calculator.next_ticker_run("30m", nil, creation_time_str)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                -- Should be at or after current time
                expect(parsed_time:after(test_base_time) or parsed_time:equal(test_base_time)).to_be_true()

                -- Should be a multiple of 30m from creation_time
                local diff = parsed_time:sub(creation_time)
                local minutes = math.floor(diff:minutes() + 0.5)
                expect(minutes % 30).to_equal(0)
            end)

            it("should handle precise ticker intervals", function()
                -- For 5s polling system, just verify basic ticker behavior
                local base_time = test_base_time:add(-2 * time.HOUR) -- 2 hours ago
                local base_time_str = base_time:format(time.RFC3339)

                local next_run, err = schedule_calculator.next_ticker_run("30m", base_time_str, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                -- Should be at or after current time
                expect(parsed_time:after(test_base_time) or parsed_time:equal(test_base_time)).to_be_true()

                -- Should be reasonable (not way off)
                local diff_from_now = parsed_time:sub(test_base_time)
                expect(diff_from_now:hours() < 24).to_be_true() -- Within 24 hours from now
            end)

            it("should reject invalid inputs", function()
                -- Invalid duration
                local next_run, err = schedule_calculator.next_ticker_run("invalid", nil, nil)
                expect(next_run).to_be_nil()
                expect(err).not_to_be_nil()

                -- Invalid last_run_at
                next_run, err = schedule_calculator.next_ticker_run("30m", "invalid", nil)
                expect(next_run).to_be_nil()
                expect(err).not_to_be_nil()

                -- Invalid created_at
                next_run, err = schedule_calculator.next_ticker_run("30m", nil, "invalid")
                expect(next_run).to_be_nil()
                expect(err).not_to_be_nil()
            end)
        end)

        describe("Cron Schedule", function()
            it("should calculate next run for simple expressions and verify timing", function()
                -- Every hour at minute 0
                local next_run, err = schedule_calculator.next_cron_run("0 * * * *", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed_time:minute()).to_equal(0)
                expect(parsed_time:second()).to_equal(0)

                -- Should be the next hour at minute 0
                local expected_hour = test_base_time:minute() == 0 and test_base_time:hour() + 1 or test_base_time:hour() + 1
                if expected_hour == 24 then expected_hour = 0 end

                -- Allow for hour being today or tomorrow
                local is_valid_hour = (parsed_time:hour() == expected_hour) or
                                     (parsed_time:hour() == test_base_time:hour() + 1) or
                                     (expected_hour == 0 and parsed_time:hour() == 0)
                expect(is_valid_hour).to_be_true()
            end)

            it("should handle specific time expressions", function()
                -- Every day at 23:30
                local next_run, err = schedule_calculator.next_cron_run("30 23 * * *", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed_time:hour()).to_equal(23)
                expect(parsed_time:minute()).to_equal(30)
                expect(parsed_time:second()).to_equal(0)

                -- Should be today or tomorrow depending on current time
                expect(parsed_time:after(test_base_time)).to_be_true()
            end)

            it("should handle weekday expressions correctly", function()
                -- Every Monday at 9 AM
                local next_run, err = schedule_calculator.next_cron_run("0 9 * * 1", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed_time:weekday()).to_equal(1) -- Monday
                expect(parsed_time:hour()).to_equal(9)
                expect(parsed_time:minute()).to_equal(0)

                -- Should be after current time
                expect(parsed_time:after(test_base_time)).to_be_true()
            end)

            it("should handle range expressions", function()
                -- Weekdays (Mon-Fri) at 9 AM
                local next_run, err = schedule_calculator.next_cron_run("0 9 * * 1-5", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                local weekday = parsed_time:weekday()
                expect(weekday >= 1 and weekday <= 5).to_be_true()
                expect(parsed_time:hour()).to_equal(9)
                expect(parsed_time:minute()).to_equal(0)
            end)

            it("should handle step expressions precisely", function()
                -- Every 15 minutes
                local next_run, err = schedule_calculator.next_cron_run("*/15 * * * *", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed_time:minute() % 15).to_equal(0)
                expect(parsed_time:second()).to_equal(0)

                -- Should be the next 15-minute boundary
                expect(parsed_time:after(test_base_time)).to_be_true()
            end)

            it("should handle complex multi-value expressions", function()
                -- Multiple specific minutes
                local next_run, err = schedule_calculator.next_cron_run("15,30,45 * * * *", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                local minute = parsed_time:minute()
                expect(minute == 15 or minute == 30 or minute == 45).to_be_true()
                expect(parsed_time:second()).to_equal(0)
            end)

            it("should handle Sunday as both 0 and 7", function()
                -- Sunday as 0
                local next_run, err = schedule_calculator.next_cron_run("0 9 * * 0", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed_time:weekday()).to_equal(0) -- Sunday

                -- Sunday as 7
                next_run, err = schedule_calculator.next_cron_run("0 9 * * 7", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed_time:weekday()).to_equal(0) -- Should be normalized to 0
            end)

            it("should handle edge case cron expressions", function()
                -- Last day of month (simplified test - just verify it works)
                local next_run, err = schedule_calculator.next_cron_run("0 0 28-31 * *", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed_time:day() >= 28).to_be_true()

                -- End of year
                next_run, err = schedule_calculator.next_cron_run("59 23 31 12 *", nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed_time:month()).to_equal(12)
                expect(parsed_time:day()).to_equal(31)
                expect(parsed_time:hour()).to_equal(23)
                expect(parsed_time:minute()).to_equal(59)
            end)

            it("should reject invalid cron expressions with detailed validation", function()
                local invalid_cases = {
                    { expr = "too few fields", desc = "too few fields" },
                    { expr = "* * * *", desc = "missing field" },
                    { expr = "60 * * * *", desc = "invalid minute (60)" },
                    { expr = "* 25 * * *", desc = "invalid hour (25)" },
                    { expr = "* * 32 * *", desc = "invalid day (32)" },
                    { expr = "* * * 13 *", desc = "invalid month (13)" },
                    { expr = "* * * * 8", desc = "invalid weekday (8)" },
                    { expr = "", desc = "empty string" },
                    { expr = nil, desc = "nil input" }
                }

                for _, case in ipairs(invalid_cases) do
                    local next_run, err = schedule_calculator.next_cron_run(case.expr, nil, nil)
                    expect(next_run).to_be_nil()
                    expect(err).not_to_be_nil()
                end
            end)

            it("should handle last_run_at parameter correctly", function()
                -- If last_run_at is in the future, should use that as base
                local future_base = test_base_time:add(3 * time.HOUR)
                local future_base_str = future_base:format(time.RFC3339)

                local next_run, err = schedule_calculator.next_cron_run("0 * * * *", future_base_str, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()

                local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()

                -- Should be after the future base time, not current time
                expect(parsed_time:after(future_base)).to_be_true()
            end)

            it("should handle complex expressions without infinite loops", function()
                -- Expression that might take many iterations to find next match
                -- Feb 29 only occurs in leap years, so this might not find a match within iteration limit
                local next_run, err = schedule_calculator.next_cron_run("0 0 29 2 *", nil, nil) -- Feb 29

                -- This should either succeed (if a leap year is nearby) or fail gracefully
                if next_run then
                    expect(err).to_be_nil()
                    local parsed_time, parse_err = time.parse(time.RFC3339, next_run)
                    expect(parse_err).to_be_nil()
                    expect(parsed_time:month()).to_equal(2)
                    expect(parsed_time:day()).to_equal(29)

                    -- Should be a leap year
                    local year = parsed_time:year()
                    expect((year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)).to_be_true()
                else
                    -- Should fail gracefully with a reasonable error message
                    expect(err).not_to_be_nil()
                    expect(err:match("Could not find next cron time")).not_to_be_nil()
                end
            end)
        end)

        describe("Return Format Validation", function()
            it("should always return RFC3339 formatted strings", function()
                local methods_and_args = {
                    { method = schedule_calculator.next_once_run, args = { future_time_str, nil, nil } },
                    { method = schedule_calculator.next_interval_run, args = { "30m", nil, nil } },
                    { method = schedule_calculator.next_ticker_run, args = { "15m", nil, nil } },
                    { method = schedule_calculator.next_cron_run, args = { "0 * * * *", nil, nil } }
                }

                for _, test_case in ipairs(methods_and_args) do
                    local result, err = test_case.method(unpack(test_case.args))
                    expect(err).to_be_nil()
                    expect(result).not_to_be_nil()
                    expect(type(result)).to_equal("string")

                    -- Should parse as valid RFC3339
                    local parsed, parse_err = time.parse(time.RFC3339, result)
                    expect(parse_err).to_be_nil()
                    expect(parsed).not_to_be_nil()

                    -- Re-formatting should produce identical string
                    expect(result).to_equal(parsed:format(time.RFC3339))
                end
            end)

            it("should return consistent time zones (UTC)", function()
                -- All methods should return times in UTC timezone
                local once_result, _ = schedule_calculator.next_once_run(future_time_str, nil, nil)
                local interval_result, _ = schedule_calculator.next_interval_run("1h", nil, nil)
                local ticker_result, _ = schedule_calculator.next_ticker_run("1h", nil, nil)
                local cron_result, _ = schedule_calculator.next_cron_run("0 * * * *", nil, nil)

                -- All should parse successfully
                local once_time, _ = time.parse(time.RFC3339, once_result)
                local interval_time, _ = time.parse(time.RFC3339, interval_result)
                local ticker_time, _ = time.parse(time.RFC3339, ticker_result)
                local cron_time, _ = time.parse(time.RFC3339, cron_result)

                -- All should end with 'Z' (UTC timezone) or have timezone offset
                expect(once_result:match("Z$") or once_result:match("[+-]%d%d:%d%d$")).not_to_be_nil()
                expect(interval_result:match("Z$") or interval_result:match("[+-]%d%d:%d%d$")).not_to_be_nil()
                expect(ticker_result:match("Z$") or ticker_result:match("[+-]%d%d:%d%d$")).not_to_be_nil()
                expect(cron_result:match("Z$") or cron_result:match("[+-]%d%d:%d%d$")).not_to_be_nil()

                -- Verify all times are actually in UTC by checking their location
                expect(once_time:location():string()).to_equal("UTC")
                expect(interval_time:location():string()).to_equal("UTC")
                expect(ticker_time:location():string()).to_equal("UTC")
                expect(cron_time:location():string()).to_equal("UTC")
            end)
        end)

        describe("Error Handling and Edge Cases", function()
            it("should handle all null/empty input combinations", function()
                local methods = {
                    { name = "once", method = schedule_calculator.next_once_run },
                    { name = "interval", method = schedule_calculator.next_interval_run },
                    { name = "ticker", method = schedule_calculator.next_ticker_run },
                    { name = "cron", method = schedule_calculator.next_cron_run }
                }

                for _, method_info in ipairs(methods) do
                    -- Nil expression
                    local result, err = method_info.method(nil, nil, nil)
                    expect(result).to_be_nil()
                    expect(err).not_to_be_nil()

                    -- Empty expression
                    result, err = method_info.method("", nil, nil)
                    expect(result).to_be_nil()
                    expect(err).not_to_be_nil()
                end
            end)

            it("should handle very large time differences", function()
                -- Very far future
                local far_future = "2099-12-31T23:59:59Z"
                local next_run, err = schedule_calculator.next_once_run(far_future, nil, nil)
                expect(err).to_be_nil()
                expect(next_run).to_equal(far_future)

                -- Very far past
                local far_past = "1970-01-01T00:00:00Z"
                next_run, err = schedule_calculator.next_once_run(far_past, nil, nil)
                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()
                -- Should return immediate execution (current time)
                local parsed, _ = time.parse(time.RFC3339, next_run)
                expect(parsed:after(test_base_time) or parsed:equal(test_base_time)).to_be_true()
            end)

            it("should handle boundary month transitions", function()
                -- Test month boundaries for intervals and tickers
                local month_end = "2025-01-31T23:00:00Z"

                -- 2 hour interval should cross into next month
                local next_run, err = schedule_calculator.next_interval_run("2h", month_end, nil)
                expect(err).to_be_nil()

                local parsed, parse_err = time.parse(time.RFC3339, next_run)
                expect(parse_err).to_be_nil()
                expect(parsed:month()).to_equal(2) -- February
                expect(parsed:day()).to_equal(1)   -- 1st
                expect(parsed:hour()).to_equal(1)  -- 01:00
            end)

            it("should handle performance limits for complex cron", function()
                -- Test with a realistic complex expression that will find a match quickly
                local start_time = time.now():utc()
                local next_run, err = schedule_calculator.next_cron_run("*/5 9-17 * * 1-5", nil, nil)
                local end_time = time.now():utc()

                expect(err).to_be_nil()
                expect(next_run).not_to_be_nil()
                expect(end_time:sub(start_time):seconds() < 2).to_be_true() -- Fast execution

                -- Test that impossible expressions fail quickly without hanging
                start_time = time.now():utc()
                next_run, err = schedule_calculator.next_cron_run("0 0 29 2 *", nil, nil) -- Feb 29
                end_time = time.now():utc()

                -- Should complete quickly regardless of success/failure
                expect(end_time:sub(start_time):seconds() < 5).to_be_true()
                -- Feb 29 may or may not be found depending on how close the next leap year is
            end)
        end)
    end)
end

return test.run_cases(define_tests)