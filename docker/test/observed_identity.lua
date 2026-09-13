local runtime = require("runtime")
local io = require("io")

local function main()
    local problems: {string} = {}
    local actual = "sha256:" .. string.rep("a", 64)
    local claimed = "sha256:" .. string.rep("b", 64)
    local started_at = "2026-09-13T12:34:56.123456789Z"
    for _, state in ipairs({"created", "running", "paused", "restarting", "removing", "exited", "dead"}) do
        local value, err = runtime.inspect_with({backend_ref = "container-one"}, {
            client = function() return {
                inspect_container = function() return {
                    Id = "container-one", Image = actual, State = {Status = state, StartedAt = started_at},
                    Config = {Labels = {["bee.image_digest"] = claimed}},
                } end,
            } end,
        })
        if err or not value or value.state ~= state then problems[#problems + 1] = state .. ": observed state changed" end
        if value and value.observed_image_digest ~= actual then problems[#problems + 1] = state .. ": label replaced observed image identity" end
        if value and value.started_at ~= started_at then problems[#problems + 1] = state .. ": execution start timestamp was lost" end
    end
    local unreported = runtime.inspect_with({backend_ref = "container-one"}, {
        client = function() return {
            inspect_container = function() return {Id = "container-one", Config = {Labels = {["bee.image_digest"] = claimed}}} end,
        } end,
    })
    if not unreported or unreported.state ~= "unknown" or unreported.observed_image_digest ~= "" or unreported.started_at ~= nil then
        problems[#problems + 1] = "missing daemon facts were invented from labels or defaults"
    end
    for _, invalid in ipairs({false, 123, "", string.rep("x", 65), "2026-09-13\n"}) do
        local malformed = runtime.inspect_with({backend_ref = "container-one"}, {
            client = function() return {
                inspect_container = function() return {Id = "container-one", State = {Status = "running", StartedAt = invalid}} end,
            } end,
        })
        if not malformed or malformed.started_at ~= nil then problems[#problems + 1] = "invalid execution timestamp was published" end
    end
    local replacement_at = "2026-09-13T12:35:00.987654321Z"
    local replacement = runtime.inspect_with({backend_ref = "container-one"}, {
        client = function() return {
            inspect_container = function() return {Id = "container-one", Image = actual,
                State = {Status = "running", StartedAt = replacement_at}, Config = {Labels = {["bee.image_digest"] = claimed}}} end,
        } end,
    })
    if not replacement or replacement.backend_ref ~= "container-one" or replacement.started_at ~= replacement_at then
        problems[#problems + 1] = "replacement execution on the same container was not distinguishable"
    end
    local calls = 0
    local stopped, stop_error = runtime.stop_with({backend_ref = "container-one"}, {
        client = function() return {
            inspect_container = function() return {Id = "container-one", Image = actual, State = {Status = "paused"}} end,
            stop_container = function() calls = calls + 1; return true end,
        } end,
    })
    if stopped ~= nil or stop_error == nil or calls ~= 1 then
        problems[#problems + 1] = "paused container was reported stopped without a terminal observation"
    end
    local stop_calls = 0
    local finished, finish_error = runtime.stop_with({backend_ref = "container-one"}, {
        client = function() return {
            inspect_container = function()
                return {Id = "container-one", Image = actual, State = {Status = stop_calls == 0 and "paused" or "exited"}}
            end,
            stop_container = function() stop_calls = stop_calls + 1; return true end,
        } end,
    })
    if not finished or finish_error or finished.state ~= "stopped" or stop_calls ~= 1 then
        problems[#problems + 1] = "confirmed exit after stopping a paused container was refused"
    end
    if #problems > 0 then error(table.concat(problems, "; ")) end
    io.print("PASS: daemon state/image evidence and paused-stop refusal")
    return true
end
return {main = main}
