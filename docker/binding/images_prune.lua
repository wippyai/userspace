local docker_client = require("docker_client")

local function handle(input: {dangling_only: boolean?})
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local dangling = true
    if input and input.dangling_only == false then
        dangling = false
    end

    local result, err = docker:prune_images(dangling)
    if err then
        return { success = false, error = tostring(err) }
    end

    return {
        success = true,
        images_deleted = result.ImagesDeleted or {},
        space_reclaimed = result.SpaceReclaimed or 0,
    }
end

return { handle = handle }
