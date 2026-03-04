local docker_client = require("docker_client")

local function handle(input: {name: string})
    if not input.name or input.name == "" then
        return { success = false, error = "name is required" }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local vol, err = docker:inspect_volume(input.name)
    if err then
        return { success = false, error = tostring(err) }
    end

    return {
        success = true,
        volume = {
            name = vol.Name,
            driver = vol.Driver,
            mountpoint = vol.Mountpoint,
            scope = vol.Scope,
            labels = vol.Labels,
            options = vol.Options,
            created_at = vol.CreatedAt,
        },
    }
end

return { handle = handle }
