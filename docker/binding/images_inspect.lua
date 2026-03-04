local docker_client = require("docker_client")

local function handle(input: {name: string})
    if not input.name or input.name == "" then
        return { success = false, error = "name is required" }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local img, err = docker:inspect_image(input.name)
    if err then
        return { success = false, error = tostring(err) }
    end

    return {
        success = true,
        image = {
            id = img.Id,
            repo_tags = img.RepoTags or {},
            repo_digests = img.RepoDigests or {},
            size = img.Size or 0,
            virtual_size = img.VirtualSize or 0,
            created = img.Created,
            architecture = img.Architecture,
            os = img.Os,
            author = img.Author,
            docker_version = img.DockerVersion,
        },
    }
end

return { handle = handle }
