local docker_client = require("docker_client")

local function handle(input: {name: string, driver: string?})
    if not input.name or input.name == "" then
        return { success = false, error = "name is required" }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local result, err = docker:create_volume(input.name, input.driver)
    if err then
        return { success = false, error = tostring(err) }
    end

    return { success = true, name = result.Name, driver = result.Driver, mountpoint = result.Mountpoint }
end

return { handle = handle }
