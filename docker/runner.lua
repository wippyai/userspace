local io = require("io")
local registry = require("registry")
local funcs = require("funcs")
local time = require("time")

local reset = "\027[0m"
local function bold(s: string) return "\027[1m" .. s .. reset end
local function red(s: string) return "\027[31m" .. s .. reset end
local function green(s: string) return "\027[32m" .. s .. reset end
local function dim(s: string) return "\027[2m" .. s .. reset end
local function cyan(s: string) return "\027[36m" .. s .. reset end

local function short_name(id: string)
    return id:match(":([^:]+)$") or id
end

local function format_duration(ms: number)
    if ms < 1 then return dim("<1ms") end
    if ms < 1000 then return dim(string.format("%dms", ms)) end
    return dim(string.format("%.1fs", ms / 1000))
end

local function main()
    time.sleep(200 * time.MILLISECOND)

    io.print("")
    io.print(bold(cyan("  Docker Demo Tests")))
    io.print("")

    local entries, err = registry.find({ ["meta.type"] = "test" })
    if err then
        io.print(red("  Error: " .. tostring(err)))
        return 1
    end

    if not entries or #entries == 0 then
        io.print("  No tests found")
        return 0
    end

    local test_entries = {}
    for _, entry in ipairs(entries) do
        if entry.meta and entry.meta.suite then
            table.insert(test_entries, entry)
        end
    end

    if #test_entries == 0 then
        io.print("  No tests found")
        return 0
    end

    table.sort(test_entries, function(a, b) return a.id < b.id end)

    io.print(dim("  " .. #test_entries .. " tests"))
    io.print("")

    local passed = 0
    local failed = 0
    local failures = {}
    local start_time = time.now()

    for _, entry in ipairs(test_entries) do
        local name = short_name(entry.id)
        local suite = entry.meta.suite
        local label = suite .. "/" .. name

        local test_start = time.now()
        local ok, result, call_err = pcall(function()
            return funcs.call(entry.id)
        end)
        local elapsed = time.now():sub(test_start):milliseconds()

        if not ok then
            failed = failed + 1
            table.insert(failures, { label = label, error = result })
            io.print("  " .. red("FAIL") .. "  " .. label .. "  " .. format_duration(elapsed))
        elseif call_err then
            failed = failed + 1
            table.insert(failures, { label = label, error = call_err })
            io.print("  " .. red("FAIL") .. "  " .. label .. "  " .. format_duration(elapsed))
        else
            passed = passed + 1
            io.print("  " .. green("PASS") .. "  " .. label .. "  " .. format_duration(elapsed))
        end
    end

    local total_elapsed = time.now():sub(start_time):milliseconds()

    if #failures > 0 then
        io.print("")
        io.print(bold(red("  Failures")))
        for _, f in ipairs(failures) do
            io.print("")
            io.print("    " .. cyan(f.label))
            io.print("    " .. red(tostring(f.error)))
        end
    end

    io.print("")
    if failed > 0 then
        io.print("  " .. red(bold("FAILED")) .. "  " .. green(passed .. " passed") .. "  " .. red(failed .. " failed") .. "  " .. format_duration(total_elapsed))
    else
        io.print("  " .. green(bold("PASSED")) .. "  " .. green(passed .. " tests") .. "  " .. format_duration(total_elapsed))
    end
    io.print("")

    return failed > 0 and 1 or 0
end

return { main = main }
