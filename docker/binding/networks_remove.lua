local docker_client = require("docker_client")

local function handle(input: {id: string})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local _, err = docker:remove_network(input.id)
    if err then
        return { success = false, error = tostring(err) }
    end

    return { success = true }
end

return { handle = handle }
