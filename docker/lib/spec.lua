local spec = {}

function spec.build_container_config(c: {
    image: string,
    command: string?,
    env: {[string]: string}?,
    volumes: {host: string, container: string, mode: string?}[]?,
    ports: {host: number, container: number, protocol: string?}[]?,
    network: string?,
    work_dir: string?,
    user: string?,
    memory_limit: number?,
    cpu_quota: number?,
    interactive: boolean?,
})
    local env_array = nil
    if c.env then
        env_array = {}
        for key, value in pairs(c.env) do
            table.insert(env_array, key .. "=" .. value)
        end
    end

    local binds = nil
    if c.volumes then
        binds = {}
        for _, vol in ipairs(c.volumes) do
            local mount = vol.host .. ":" .. vol.container
            if vol.mode == "ro" then
                mount = mount .. ":ro"
            end
            table.insert(binds, mount)
        end
    end

    local host_config = {
        AutoRemove = false,
        ExtraHosts = { "host.docker.internal:host-gateway" },
    }

    if binds and #binds > 0 then
        host_config.Binds = binds
    end

    if c.ports then
        local port_bindings = {}
        for _, p in ipairs(c.ports) do
            local proto = p.protocol or "tcp"
            local key = tostring(p.container) .. "/" .. proto
            port_bindings[key] = { { HostPort = tostring(p.host) } }
        end
        if next(port_bindings) then
            host_config.PortBindings = port_bindings
        end
    end

    if c.network then
        host_config.NetworkMode = c.network
    end

    if c.memory_limit then
        host_config.Memory = c.memory_limit
    end

    if c.cpu_quota then
        host_config.NanoCPUs = math.floor(c.cpu_quota * 1e9)
    end

    local cmd = nil
    if c.command then
        cmd = { "sh", "-c", c.command }
    end

    local config = {
        Image = c.image,
        Cmd = cmd,
        Env = env_array,
        User = c.user or "",
        WorkingDir = c.work_dir or "",
        OpenStdin = c.interactive or false,
        AttachStdin = c.interactive or false,
        AttachStdout = true,
        AttachStderr = true,
        Tty = false,
        HostConfig = host_config,
    }

    return config
end

function spec.validate(s: {image: string?}?)
    if not s then
        return nil, "spec is required"
    end
    if not s.image or s.image == "" then
        return nil, "image is required"
    end
    return true
end

return spec
