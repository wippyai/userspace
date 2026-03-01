local docker_client = require("docker_client")

local function handle(input: table?)
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local info, err = docker:system_info()
    if err then
        return { success = false, error = tostring(err) }
    end

    return {
        success = true,
        info = {
            containers = info.Containers or 0,
            containers_running = info.ContainersRunning or 0,
            containers_paused = info.ContainersPaused or 0,
            containers_stopped = info.ContainersStopped or 0,
            images = info.Images or 0,
            driver = info.Driver,
            os = info.OperatingSystem,
            os_type = info.OSType,
            architecture = info.Architecture,
            ncpu = info.NCPU or 0,
            mem_total = info.MemTotal or 0,
            kernel_version = info.KernelVersion,
            docker_root_dir = info.DockerRootDir,
            server_version = info.ServerVersion,
            name = info.Name,
        },
    }
end

return { handle = handle }
