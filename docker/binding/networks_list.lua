local docker_client = require("docker_client")

local function handle(input: table?)
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local networks, err = docker:list_networks()
    if err then
        return { success = false, error = tostring(err) }
    end

    local result = {}
    for _, net in ipairs(networks or {}) do
        table.insert(result, {
            id = net.Id,
            name = net.Name,
            driver = net.Driver,
            scope = net.Scope,
        })
    end

    return { success = true, networks = result }
end

return { handle = handle }
