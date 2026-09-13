local runtime = require("runtime")
local io = require("io")

local function main()
    local problems: {string} = {}
    local actual = "sha256:" .. string.rep("a", 64)
    local claimed = "sha256:" .. string.rep("b", 64)
    for _, state in ipairs({"created", "running", "paused", "restarting", "removing", "exited", "dead"}) do
        local value, err = runtime.inspect_with({backend_ref = "container-one"}, {
            client = function() return {
                inspect_container = function() return {
                    Id = "container-one", Image = actual, State = {Status = state},
                    Config = {Labels = {["bee.image_digest"] = claimed}},
                } end,
            } end,
        })
        if err or not value or value.state ~= state then problems[#problems + 1] = state .. ": observed state changed" end
        if value and value.observed_image_digest ~= actual then problems[#problems + 1] = state .. ": label replaced observed image identity" end
    end
    local unreported = runtime.inspect_with({backend_ref = "container-one"}, {
        client = function() return {
            inspect_container = function() return {Id = "container-one", Config = {Labels = {["bee.image_digest"] = claimed}}} end,
        } end,
    })
    if not unreported or unreported.state ~= "unknown" or unreported.observed_image_digest ~= "" then
        problems[#problems + 1] = "missing daemon facts were invented from labels or defaults"
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
