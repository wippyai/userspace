local time = require("time")
local text = require("text")

-- Create the module table
local schedule_calculator = {}

-- =============================================================================
-- COMPILED REGEX PATTERNS (MODULE LEVEL FOR PERFORMANCE)
-- =============================================================================

-- Compile regex patterns once at module load time for better performance
local COMMA_REGEX = text.regexp.compile(",")
local STEP_REGEX = text.regexp.compile("^(.+)/([1-9][0-9]*)$")
local RANGE_REGEX = text.regexp.compile("^([0-9]+)-([0-9]+)$")
local CRON_REGEX = text.regexp.compile("^\\s*(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s*$")

-- Validate regex compilation at module load time
local function validate_regex_compilation()
    if not COMMA_REGEX then
        error("Failed to compile comma regex")
    end
    if not STEP_REGEX then
        error("Failed to compile step regex")
    end
    if not RANGE_REGEX then
        error("Failed to compile range regex")
    end
    if not CRON_REGEX then
        error("Failed to compile cron regex")
    end
end

-- Run validation immediately
validate_regex_compilation()

-- =============================================================================
-- CRON PARSING WITH PRE-COMPILED REGEX
-- =============================================================================

---Parse a cron field value using pre-compiled regex patterns
---@param field_value string The cron field value
---@param min_val integer Minimum allowed value
---@param max_val integer Maximum allowed value
---@return table|nil, string|nil Array of valid values or nil and error
local function parse_cron_field(field_value, min_val, max_val)
    local values = {}

    -- Handle wildcard
    if field_value == "*" then
        for i = min_val, max_val do
            table.insert(values, i)
        end
        return values, nil
    end

    -- Split by commas and process each part using pre-compiled regex
    local parts = COMMA_REGEX:split(field_value, -1)

    for _, part in ipairs(parts) do
        part = part:match("^%s*(.-)%s*$") -- trim whitespace

        -- Check for step values (e.g., */5, 1-10/2) using pre-compiled regex
        local step_match = STEP_REGEX:find_string_submatch(part :: string)
        local step = 1
        if step_match then
            part = step_match[2]                    -- base part
            step = tonumber(step_match[3]) or 1     -- step value
        end

        -- Check for ranges (e.g., 1-5) using pre-compiled regex
        local range_match = RANGE_REGEX:find_string_submatch(part :: string)
        if range_match then
            local range_start = tonumber(range_match[2])
            local range_end = tonumber(range_match[3])

            if not range_start or not range_end then
                return nil, "Invalid range values in: " .. part
            end

            for i = range_start, range_end, step do
                if i >= min_val and i <= max_val then
                    table.insert(values, i)
                end
            end
        elseif part == "*" then
            -- Wildcard with step
            for i = min_val, max_val, step do
                table.insert(values, i)
            end
        else
            -- Single value
            local val = tonumber(part)
            if val and val >= min_val and val <= max_val then
                table.insert(values, val)
            else
                return nil, "Invalid value " .. part .. " (must be " .. min_val .. "-" .. max_val .. ")"
            end
        end
    end

    -- Remove duplicates and sort
    local unique_values = {}
    local seen = {}
    for _, val in ipairs(values) do
        if not seen[val] then
            seen[val] = true
            table.insert(unique_values, val)
        end
    end

    table.sort(unique_values)
    return unique_values, nil
end

---Parse a cron expression into component arrays using pre-compiled regex
---@param cron_expr string The cron expression
---@return table|nil, string|nil Parsed cron components or nil and error
local function parse_cron_expression(cron_expr)
    if not cron_expr or type(cron_expr) ~= "string" then
        return nil, "Invalid cron expression"
    end

    -- Use pre-compiled regex to split and validate cron expression format
    local match = CRON_REGEX:find_string_submatch(cron_expr)
    if not match or #match ~= 6 then
        return nil, "Cron expression must have exactly 5 fields: minute hour day month weekday"
    end

    local fields = { match[2], match[3], match[4], match[5], match[6] }

    local parsed = {}

    -- Parse each field with appropriate ranges
    local minutes, min_err = parse_cron_field(fields[1] :: string, 0, 59)
    if min_err then
        return nil, "Invalid minute field: " .. min_err
    end
    parsed.minutes = minutes

    local hours, hour_err = parse_cron_field(fields[2] :: string, 0, 23)
    if hour_err then
        return nil, "Invalid hour field: " .. hour_err
    end
    parsed.hours = hours

    local days, day_err = parse_cron_field(fields[3] :: string, 1, 31)
    if day_err then
        return nil, "Invalid day field: " .. day_err
    end
    parsed.days = days

    local months, month_err = parse_cron_field(fields[4] :: string, 1, 12)
    if month_err then
        return nil, "Invalid month field: " .. month_err
    end
    parsed.months = months

    local weekdays, weekday_err = parse_cron_field(fields[5] :: string, 0, 7)
    if weekday_err then
        return nil, "Invalid weekday field: " .. weekday_err
    end
    parsed.weekdays = weekdays

    -- Convert Sunday from 7 to 0 for weekdays
    for i, weekday in ipairs(parsed.weekdays) do
        if weekday == 7 then
            parsed.weekdays[i] = 0
        end
    end

    -- Remove duplicates from weekdays after conversion
    local unique_weekdays = {}
    local seen = {}
    for _, weekday in ipairs(parsed.weekdays) do
        if not seen[weekday] then
            seen[weekday] = true
            table.insert(unique_weekdays, weekday)
        end
    end
    table.sort(unique_weekdays)
    parsed.weekdays = unique_weekdays

    return parsed, nil
end

---Check if a value is in an array
---@param array table
---@param value any
---@return boolean
local function array_contains(array, value)
    for _, v in ipairs(array) do
        if v == value then
            return true
        end
    end
    return false
end

---Check if a time matches the cron specification
---@param time_obj table Time object
---@param cron_spec table Parsed cron specification
---@return boolean
local function time_matches_cron(time_obj, cron_spec)
    local minute = time_obj:minute()
    local hour = time_obj:hour()
    local day = time_obj:day()
    local month = time_obj:month()
    local weekday = time_obj:weekday()

    return array_contains(cron_spec.minutes, minute) and
        array_contains(cron_spec.hours, hour) and
        array_contains(cron_spec.days, day) and
        array_contains(cron_spec.months, month) and
        array_contains(cron_spec.weekdays, weekday)
end

---Find the next time that matches a cron expression
---@param cron_spec table Parsed cron specification
---@param from_time table Starting time (must be UTC)
---@param max_iterations integer Maximum iterations to prevent infinite loops
---@return table|nil Next matching time or nil if none found
local function find_next_cron_time(cron_spec, from_time, max_iterations)
    max_iterations = max_iterations or 366 * 24 * 60 -- About a year in minutes

    -- Start from the next minute to avoid immediate re-execution
    local one_minute, duration_err = time.parse_duration("1m")
    if duration_err then
        return nil
    end

    local current_time = from_time:add(one_minute)
    -- Truncate to the minute (set seconds and nanoseconds to 0)
    -- Ensure we maintain UTC timezone
    current_time = time.date(
        current_time:year(),
        current_time:month(),
        current_time:day(),
        current_time:hour(),
        current_time:minute(),
        0,       -- seconds
        0,       -- nanoseconds
        time.utc -- Always use UTC location
    )

    for i = 1, max_iterations do
        if time_matches_cron(current_time, cron_spec) then
            return current_time
        end

        -- Advance by one minute
        current_time = current_time:add(one_minute)
    end

    return nil -- No match found within reasonable time
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

---Calculate next run time for a "once" schedule
---@param expression string ISO timestamp
---@param last_run_at string|nil When task last ran (ISO string)
---@param created_at string|nil When schedule was created (ISO string, ignored)
---@return string|nil, string|nil next_run_time, error
function schedule_calculator.next_once_run(expression, last_run_at, created_at)
    if not expression or type(expression) ~= "string" or expression == "" then
        return nil, "Once schedule requires a timestamp expression"
    end

    -- If already run, no next run time
    if last_run_at then
        return nil, nil -- No error, just no next run
    end

    -- Parse the target time
    local target_time, parse_err = time.parse(time.RFC3339, expression)
    if parse_err then
        return nil, "Invalid timestamp format: " .. parse_err
    end

    -- Convert to UTC to ensure consistent storage
    target_time = target_time:utc()

    -- Check if the time is in the future
    local now = time.now():utc()
    if target_time:after(now) then
        return target_time:format(time.RFC3339), nil
    else
        -- Time has passed, should run immediately (return current time)
        return now:format(time.RFC3339), nil
    end
end

---Calculate next run time for an "interval" schedule
---@param expression string Duration string (e.g., "5m", "1h30m")
---@param last_run_at string|nil When task last completed (ISO string)
---@param created_at string|nil When schedule was created (ISO string, ignored)
---@return string|nil, string|nil next_run_time, error
function schedule_calculator.next_interval_run(expression, last_run_at, created_at)
    if not expression or type(expression) ~= "string" or expression == "" then
        return nil, "Interval schedule requires a duration expression"
    end

    -- Parse the interval duration
    local duration, parse_err = time.parse_duration(expression)
    if parse_err then
        return nil, "Invalid duration format: " .. parse_err
    end

    local base_time
    if last_run_at then
        -- Add interval to last completion time
        local last_time, last_err = time.parse(time.RFC3339, last_run_at)
        if last_err then
            return nil, "Invalid last_run_at format: " .. last_err
        end
        -- Convert to UTC for consistent calculations
        base_time = last_time:utc()
    else
        -- First run - schedule for now
        base_time = time.now():utc()
    end

    local next_time = base_time:add(duration)
    return next_time:format(time.RFC3339), nil
end

---Calculate next run time for a "ticker" schedule
---@param expression string Duration string (e.g., "15m", "2h")
---@param last_run_at string|nil When task was last scheduled (ISO string)
---@param created_at string|nil When schedule was created (ISO string)
---@return string|nil, string|nil next_run_time, error
function schedule_calculator.next_ticker_run(expression, last_run_at, created_at)
    if not expression or type(expression) ~= "string" or expression == "" then
        return nil, "Ticker schedule requires a duration expression"
    end

    -- Parse the ticker interval
    local interval, parse_err = time.parse_duration(expression)
    if parse_err then
        return nil, "Invalid duration format: " .. parse_err
    end

    local base_time
    if last_run_at then
        -- Add interval to last scheduled time (not completion time)
        local last_time, last_err = time.parse(time.RFC3339, last_run_at)
        if last_err then
            return nil, "Invalid last_run_at format: " .. last_err
        end
        -- Convert to UTC for consistent calculations
        base_time = last_time:utc()
    elseif created_at then
        -- First run - use creation time as base
        local created_time, created_err = time.parse(time.RFC3339, created_at)
        if created_err then
            return nil, "Invalid created_at format: " .. created_err
        end
        -- Convert to UTC for consistent calculations
        base_time = created_time:utc()
    else
        -- Fallback to current time
        base_time = time.now():utc()
    end

    -- Find the next tick time at or after now
    local now = time.now():utc()
    local next_time = base_time:add(interval)

    -- If next time is in the past, calculate how many intervals to skip
    while next_time:before(now) do
        next_time = next_time:add(interval)
    end

    return next_time:format(time.RFC3339), nil
end

---Calculate next run time for a "cron" schedule
---@param expression string Cron expression (e.g., "0 9 * * MON-FRI")
---@param last_run_at string|nil When task last ran (ISO string)
---@param created_at string|nil When schedule was created (ISO string, ignored)
---@return string|nil, string|nil next_run_time, error
function schedule_calculator.next_cron_run(expression, last_run_at, created_at)
    if not expression or type(expression) ~= "string" or expression == "" then
        return nil, "Cron schedule requires a cron expression"
    end

    -- Parse the cron expression using pre-compiled regex patterns
    local cron_spec, parse_err = parse_cron_expression(expression)
    if parse_err then
        return nil, "Invalid cron expression: " .. parse_err
    end

    -- Calculate from current time or last run time
    local from_time = time.now():utc()
    if last_run_at then
        local last_time, last_err = time.parse(time.RFC3339, last_run_at)
        if last_err then
            return nil, "Invalid last_run_at format: " .. last_err
        end
        -- Convert to UTC and use the later of last run time or current time
        last_time = last_time:utc()
        if last_time:after(from_time) then
            from_time = last_time
        end
    end

    -- Find the next matching time
    local next_time = find_next_cron_time(cron_spec, from_time)
    if not next_time then
        return nil, "Could not find next cron time within reasonable period"
    end

    return next_time:format(time.RFC3339), nil
end

return schedule_calculator
