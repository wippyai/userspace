local docker_client = require("docker_client")

local function handle(input: table?)
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local ver, err = docker:system_version()
    if err then
        return { success = false, error = tostring(err) }
    end

    return {
        success = true,
        version = {
            version = ver.Version,
            api_version = ver.ApiVersion,
            min_api_version = ver.MinAPIVersion,
            git_commit = ver.GitCommit,
            go_version = ver.GoVersion,
            os = ver.Os,
            arch = ver.Arch,
            kernel_version = ver.KernelVersion,
            build_time = ver.BuildTime,
        },
    }
end

return { handle = handle }
