local docker_client = require("docker_client")

local function handle(input: table?)
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local result, err = docker:prune_volumes()
    if err then
        return { success = false, error = tostring(err) }
    end

    return {
        success = true,
        volumes_deleted = result.VolumesDeleted or {},
        space_reclaimed = result.SpaceReclaimed or 0,
    }
end

return { handle = handle }
