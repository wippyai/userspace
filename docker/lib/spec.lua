local spec = {}

function spec.build_container_config(c: {
    image: string,
    command: string?,
    env: {[string]: string}?,
    volumes: {host: string, container: string, mode: string?}[]?,
    ports: {host: number, container: number, protocol: string?}[]?,
    network: string?,
    hostname: string?,
    work_dir: string?,
    user: string?,
    memory_limit: number?,
    cpu_quota: number?,
    interactive: boolean?,
    labels: {[string]: string}?,
    extra_hosts: {string}?,
    restart_policy: {name: string, max_retry: number?}?,
    healthcheck: {test: {string}, interval: number?, timeout: number?, retries: number?, start_period: number?}?,
    cap_add: {string}?,
    dns: {string}?,
    group_add: {string}?,
    devices: {table}?,
    device_requests: {table}?,
    args: {string}?,
    entrypoint: {string}?,
}): {[string]: any}
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

    local host_config: {[string]: any} = {
        AutoRemove = false,
    }

    -- Extra hosts: default includes host.docker.internal, caller can override
    if c.extra_hosts then
        host_config.ExtraHosts = c.extra_hosts
    else
        host_config.ExtraHosts = { "host.docker.internal:host-gateway" }
    end

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

    if c.restart_policy then
        host_config.RestartPolicy = {
            Name = c.restart_policy.name,
            MaximumRetryCount = c.restart_policy.max_retry or 0,
        }
    end

    if c.cap_add then
        host_config.CapAdd = c.cap_add
    end

    if c.dns then
        host_config.Dns = c.dns
    end

    if c.group_add then
        host_config.GroupAdd = c.group_add
    end

    if c.devices then
        local devices = {}
        for _, d in ipairs(c.devices) do
            table.insert(devices, {
                PathOnHost = d.path_on_host or d.PathOnHost,
                PathInContainer = d.path_in_container or d.PathInContainer or d.path_on_host or d.PathOnHost,
                CgroupPermissions = d.cgroup_permissions or d.CgroupPermissions or "rwm",
            })
        end
        if #devices > 0 then host_config.Devices = devices end
    end

    if c.device_requests then
        local requests = {}
        for _, r in ipairs(c.device_requests) do
            table.insert(requests, {
                Driver = r.driver or r.Driver,
                Count = r.count or r.Count or 0,
                DeviceIDs = r.device_ids or r.DeviceIDs,
                Capabilities = r.capabilities or r.Capabilities,
                Options = r.options or r.Options,
            })
        end
        if #requests > 0 then host_config.DeviceRequests = requests end
    end

    -- args run as raw Cmd against the image entrypoint (e.g. an ENTRYPOINT-based
    -- server image taking flags); command is the shell convenience form wrapped in
    -- sh -c. args takes precedence when both are given.
    local cmd = nil
    if c.args then
        cmd = c.args
    elseif c.command then
        cmd = { "sh", "-c", c.command }
    end

    local config: {[string]: any} = {
        Image = c.image,
        Cmd = cmd,
        Env = env_array,
        Hostname = c.hostname or "",
        User = c.user or "",
        WorkingDir = c.work_dir or "",
        OpenStdin = c.interactive or false,
        AttachStdin = c.interactive or false,
        AttachStdout = true,
        AttachStderr = true,
        Tty = false,
        HostConfig = host_config,
    }

    if c.entrypoint then
        config.Entrypoint = c.entrypoint
    end

    if c.labels then
        config.Labels = c.labels
    end

    if c.healthcheck and c.healthcheck.test then
        local hc: {[string]: any} = {
            Test = c.healthcheck.test,
        }
        if c.healthcheck.interval then
            hc.Interval = math.floor(c.healthcheck.interval * 1e9)
        end
        if c.healthcheck.timeout then
            hc.Timeout = math.floor(c.healthcheck.timeout * 1e9)
        end
        if c.healthcheck.retries then
            hc.Retries = c.healthcheck.retries
        end
        if c.healthcheck.start_period then
            hc.StartPeriod = math.floor(c.healthcheck.start_period * 1e9)
        end
        config.Healthcheck = hc
    end

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
