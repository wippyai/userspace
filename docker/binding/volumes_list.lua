local docker_client = require("docker_client")

local function handle(input: table?)
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local result, err = docker:list_volumes()
    if err then
        return { success = false, error = tostring(err) }
    end

    local volumes = {}
    for _, vol in ipairs(result.Volumes or {}) do
        table.insert(volumes, {
            name = vol.Name,
            driver = vol.Driver,
            mountpoint = vol.Mountpoint,
            scope = vol.Scope,
        })
    end

    return { success = true, volumes = volumes }
end

return { handle = handle }
