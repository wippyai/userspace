local json = require("json")
local consts = require("consts")

local function handle(input: {container_id: string, data: string})
    if not input.container_id or input.container_id == "" then
        return { success = false, error = "container_id is required" }
    end

    if not input.data then
        return { success = false, error = "data is required" }
    end

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if not root_pid then
        return { success = false, error = "docker service not available" }
    end

    process.send(root_pid, consts.topic.STDIN, json.encode({
        container_id = input.container_id,
        data = input.data,
    }))

    return { success = true }
end

return { handle = handle }
