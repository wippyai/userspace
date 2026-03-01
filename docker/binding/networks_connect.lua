local docker_client = require("docker_client")

local function handle(input: {network_id: string, container_id: string, aliases: {string}?})
    if not input.network_id or input.network_id == "" then
        return { success = false, error = "network_id is required" }
    end
    if not input.container_id or input.container_id == "" then
        return { success = false, error = "container_id is required" }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local _, err = docker:connect_network(input.network_id, input.container_id, input.aliases)
    if err then
        return { success = false, error = tostring(err) }
    end

    return { success = true }
end

return { handle = handle }
