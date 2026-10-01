local runtime = require("runtime")
local io = require("io")

local function main()
    local checked = 0
    for _, scenario in ipairs({
        {name = "timeout", message = "deadline exceeded", status = 0, destroyed = false},
        {name = "daemon error", message = "HTTP 500", status = 500, destroyed = false},
        {name = "denied", message = "HTTP 403", status = 403, destroyed = false},
        {name = "misleading text", message = "proxy: HTTP 404 upstream unavailable", status = 0, destroyed = false},
        {name = "confirmed absence", message = "not found", status = 404, destroyed = true},
    }) do
        local reads = 0
        local removed, err = runtime.remove_with({backend_ref = "container-one"}, {
            client = function() return {
                inspect_container = function()
                    reads = reads + 1
                    if reads == 1 then
                        return {Id = "container-one", State = {Status = "exited"}, Config = {Labels = {}}}, nil, 200
                    end
                    return nil, scenario.message, scenario.status
                end,
                remove_container = function() return nil, "delete response lost" end,
            } end,
        })
        if scenario.destroyed then
            if not removed or err or removed.state ~= "destroyed" then
                error(scenario.name .. ": confirmed deletion was not reconciled")
            end
        elseif removed ~= nil or err == nil then
            error(scenario.name .. ": unavailable inspection was reported as destruction")
        end
        checked = checked + 1
    end
    io.print("PASS: " .. tostring(checked) .. " Docker removal observation cases")
    return true
end
return {main = main}
