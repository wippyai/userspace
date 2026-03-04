local docker_client = require("docker_client")

local function handle(input: table?)
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local df, err = docker:system_df()
    if err then
        return { success = false, error = tostring(err) }
    end

    local images = {}
    for _, img in ipairs(df.Images or {}) do
        table.insert(images, {
            id = img.Id,
            repo_tags = img.RepoTags or {},
            size = img.Size or 0,
            shared_size = img.SharedSize or 0,
            containers = img.Containers or 0,
        })
    end

    local containers = {}
    for _, c in ipairs(df.Containers or {}) do
        table.insert(containers, {
            id = c.Id,
            names = c.Names or {},
            image = c.Image,
            size_rw = c.SizeRw or 0,
            size_root_fs = c.SizeRootFs or 0,
            state = c.State,
        })
    end

    local volumes = {}
    for _, v in ipairs(df.Volumes or {}) do
        table.insert(volumes, {
            name = v.Name,
            driver = v.Driver,
            size = v.UsageData and v.UsageData.Size or -1,
            ref_count = v.UsageData and v.UsageData.RefCount or 0,
        })
    end

    return {
        success = true,
        images = images,
        containers = containers,
        volumes = volumes,
        layers_size = df.LayersSize or 0,
    }
end

return { handle = handle }
