local runtime = {}
type DynamicObject = {[string]: unknown}

local LABELS: {[string]: boolean} = {
    ["bee.actor_ref"] = true, ["bee.revision_digest"] = true,
    ["bee.attempt_id"] = true, ["bee.request_digest"] = true,
    ["bee.lease_fence"] = true,
}

local function object(value: unknown, allowed: {[string]: boolean}, name: string):
        (DynamicObject?, string?)
    if type(value) ~= "table" then return nil, name .. " must be an object" end
    local raw = value :: DynamicObject
    for key in pairs(raw) do
        if type(key) ~= "string" or not allowed[key] then
            return nil, name .. " contains unsupported field " .. tostring(key)
        end
    end
    return raw, nil
end

local function strings(value: unknown, name: string, maximum: number): ({string}?, string?)
    if type(value) ~= "table" then return nil, name .. " must be an array" end
    local result: {string} = {}
    for index, item in ipairs(value :: {unknown}) do
        if type(item) ~= "string" or item == "" then return nil, name .. " contains an invalid string" end
        result[index] = item
    end
    for key in pairs(value :: DynamicObject) do
        if type(key) ~= "number" or key < 1 or key > #result or key % 1 ~= 0 then
            return nil, name .. " must be dense"
        end
    end
    if #result > maximum then return nil, name .. " exceeds its entry budget" end
    return result, nil
end

local function absolute(value: unknown): boolean
    return type(value) == "string" and value ~= "" and string.sub(value, 1, 1) == "/"
        and not string.find(value, "..", 1, true) and not string.find(value, "\0", 1, true)
end

local function labels(value: unknown): (DynamicObject?, string?)
    local raw, raw_err = object(value, LABELS, "narrow Docker labels")
    if not raw then return nil, raw_err end
    for key in pairs(LABELS) do
        if type(raw[key]) ~= "string" or raw[key] == "" then
            return nil, "narrow Docker label " .. key .. " is required"
        end
    end
    return raw, nil
end

function runtime.config(value: unknown): (DynamicObject?, string?)
    local raw, raw_err = object(value, { Image = true, Cmd = true, User = true,
        WorkingDir = true, Env = true, OpenStdin = true, AttachStdin = true,
        AttachStdout = true, AttachStderr = true, Tty = true, Labels = true,
        HostConfig = true }, "narrow Docker config")
    if not raw then return nil, raw_err end
    if type(raw.Image) ~= "string" or not (string.match(raw.Image :: string,
        "^sha256:[0-9a-fA-F]+$") or string.match(raw.Image :: string,
        "^[A-Za-z0-9_./-]+@sha256:[0-9a-fA-F]+$")) then
        return nil, "narrow Docker image must be immutable"
    end
    local command, command_err = strings(raw.Cmd, "narrow Docker Cmd", 64)
    if not command or #command == 0 or not absolute(command[1]) then
        return nil, command_err or "narrow Docker Cmd requires an absolute executable"
    end
    if type(raw.User) ~= "string" or not string.match(raw.User :: string,
        "^[1-9][0-9]*:[1-9][0-9]*$") then return nil, "narrow Docker user must be non-root" end
    if not absolute(raw.WorkingDir) then return nil, "narrow Docker working directory is invalid" end
    local environment, env_err = strings(raw.Env, "narrow Docker Env", 16)
    if not environment then return nil, env_err end
    for _, item in ipairs(environment) do
        local key, path = string.match(item, "^([A-Z_]+)=(/[^%z]*)$")
        if (key ~= "HOME" and key ~= "TMPDIR") or not path then
            return nil, "narrow Docker environment contains an ambient or secret field"
        end
    end
    if raw.OpenStdin ~= true or raw.AttachStdin ~= true or raw.AttachStdout ~= true
        or raw.AttachStderr ~= true or raw.Tty ~= false then
        return nil, "narrow Docker stdio shape is unsafe"
    end
    local label_value, label_err = labels(raw.Labels)
    if not label_value then return nil, label_err end
    local host, host_err = object(raw.HostConfig, { ReadonlyRootfs = true,
        Privileged = true, CapDrop = true, SecurityOpt = true, PidsLimit = true,
        Memory = true, NanoCPUs = true, NetworkMode = true, Binds = true,
        Tmpfs = true, AutoRemove = true, ExtraHosts = true, Devices = true },
        "narrow Docker HostConfig")
    if not host then return nil, host_err end
    if host.ReadonlyRootfs ~= true or host.Privileged ~= false or host.AutoRemove ~= false then
        return nil, "narrow Docker root isolation is unsafe"
    end
    local drops = select(1, strings(host.CapDrop, "narrow Docker CapDrop", 1))
    if not drops or #drops ~= 1 or drops[1] ~= "ALL" then
        return nil, "narrow Docker must drop all capabilities"
    end
    local security, security_err = strings(host.SecurityOpt, "narrow Docker SecurityOpt", 8)
    if not security then return nil, security_err end
    local nnp, seccomp, apparmor = false, false, false
    for _, item in ipairs(security) do
        if item == "no-new-privileges:true" then nnp = true
        elseif string.match(item, "^seccomp={") then seccomp = true
        elseif string.match(item, "^apparmor=[A-Za-z0-9_.-]+$") then apparmor = true
        else return nil, "narrow Docker security option is unsupported" end
    end
    if not nnp or not seccomp or not apparmor then
        return nil, "narrow Docker requires no-new-privileges, seccomp, and AppArmor"
    end
    for _, name in ipairs({ "PidsLimit", "Memory", "NanoCPUs" }) do
        if type(host[name]) ~= "number" or (host[name] :: number) <= 0 then
            return nil, "narrow Docker " .. name .. " must be positive"
        end
    end
    if type(host.NetworkMode) ~= "string" or host.NetworkMode == ""
        or host.NetworkMode == "host" or host.NetworkMode == "default" then
        return nil, "narrow Docker network mode is unsafe"
    end
    local binds, binds_err = strings(host.Binds, "narrow Docker Binds", 16)
    if not binds then return nil, binds_err end
    if #binds < 2 then return nil, "narrow Docker requires workspace and state mounts" end
    for _, item in ipairs(binds) do
        local source, target, mode = string.match(item, "^(/[^:]+):(/[^:]+):(r[ow])$")
        if not source or not target or (mode ~= "ro" and mode ~= "rw")
            or string.find(source, "docker.sock", 1, true) then
            return nil, "narrow Docker bind is invalid"
        end
    end
    if type(host.Tmpfs) ~= "table" then return nil, "narrow Docker Tmpfs is required" end
    local count = 0
    for path, options in pairs(host.Tmpfs :: DynamicObject) do
        count = count + 1
        if not absolute(path) or options ~= "rw,nosuid,nodev,noexec" then
            return nil, "narrow Docker tmpfs is unsafe"
        end
    end
    if count ~= 1 then return nil, "narrow Docker requires one tmpfs" end
    for _, name in ipairs({ "ExtraHosts", "Devices" }) do
        if type(host[name]) ~= "table" or next(host[name] :: DynamicObject) ~= nil then
            return nil, "narrow Docker " .. name .. " must be empty"
        end
    end
    return raw, nil
end

local function observation(value: DynamicObject, forced: string?): DynamicObject
    local config = type(value.Config) == "table" and value.Config :: DynamicObject or {}
    local observed = type(value.State) == "table" and (value.State :: DynamicObject).Status or value.State
    local state = forced or (observed == "created" and "created"
        or (observed == "running" and "running" or "exited"))
    return { schema_revision = "userspace.docker.narrow-observation@1",
        backend_ref = tostring(value.Id or value.ID or ""),
        observed_image_digest = tostring(value.Image or value.ImageID or ""),
        labels = type(config.Labels) == "table" and config.Labels
            or (type(value.Labels) == "table" and value.Labels or {}), state = state }
end

local function client(deps: DynamicObject): (any?, string?) return (deps.client :: any)() end

local function ref(value: unknown, name: string): (DynamicObject?, string?)
    local raw, raw_err = object(value, { backend_ref = true, timeout_seconds = true }, name)
    if not raw then return nil, raw_err end
    if type(raw.backend_ref) ~= "string" or raw.backend_ref == "" then return nil, name .. " requires backend_ref" end
    return raw, nil
end

function runtime.create_with(value: unknown, deps: DynamicObject): (DynamicObject?, string?)
    local raw, raw_err = object(value, { name = true, config = true }, "narrow create")
    if not raw then return nil, raw_err end
    if type(raw.name) ~= "string" or not string.match(raw.name :: string, "^bee%-[0-9a-f]+$") then
        return nil, "narrow container name is invalid"
    end
    local config, config_err = runtime.config(raw.config); if not config then return nil, config_err end
    local docker, docker_err = client(deps); if not docker then return nil, docker_err end
    local created, create_err = (docker :: any):create_container(config, { name = raw.name })
    if type(created) ~= "table" or type((created :: DynamicObject).Id) ~= "string" then
        return nil, tostring(create_err or "Docker create returned no ID")
    end
    local inspected, inspect_err = (docker :: any):inspect_container((created :: DynamicObject).Id)
    if type(inspected) ~= "table" then return nil, tostring(inspect_err) end
    return observation(inspected :: DynamicObject, "created"), nil
end

function runtime.find_with(value: unknown, deps: DynamicObject): ({DynamicObject}?, string?)
    local raw, raw_err = object(value, { labels = true }, "narrow find"); if not raw then return nil, raw_err end
    local expected, label_err = labels(raw.labels); if not expected then return nil, label_err end
    local filters: {string} = {}; for key, item in pairs(expected) do filters[#filters + 1] = key .. "=" .. tostring(item) end
    table.sort(filters)
    local docker, docker_err = client(deps); if not docker then return nil, docker_err end
    local values, list_err = (docker :: any):list_containers({ label = filters })
    if type(values) ~= "table" then return nil, tostring(list_err) end
    local result: {DynamicObject} = {}
    for _, item in ipairs(values :: {unknown}) do if type(item) == "table" then result[#result + 1] = observation(item :: DynamicObject) end end
    return result, nil
end

function runtime.inspect_with(value: unknown, deps: DynamicObject): (DynamicObject?, string?)
    local raw, raw_err = ref(value, "narrow inspect"); if not raw then return nil, raw_err end
    local docker, docker_err = client(deps); if not docker then return nil, docker_err end
    local item, item_err = (docker :: any):inspect_container(raw.backend_ref)
    if type(item) ~= "table" then return nil, tostring(item_err) end
    return observation(item :: DynamicObject), nil
end

local function transition(value: unknown, deps: DynamicObject, operation: string,
        forced: string): (DynamicObject?, string?)
    local raw, raw_err = ref(value, "narrow " .. operation); if not raw then return nil, raw_err end
    local docker, docker_err = client(deps); if not docker then return nil, docker_err end
    local before: DynamicObject? = nil
    if operation == "remove" then
        local item, item_err = (docker :: any):inspect_container(raw.backend_ref)
        if type(item) ~= "table" then return nil, tostring(item_err) end
        before = item :: DynamicObject
    end
    local ok, call_err
    if operation == "start" then ok, call_err = (docker :: any):start_container(raw.backend_ref)
    elseif operation == "stop" then
        local timeout = tonumber(raw.timeout_seconds) or 10
        if timeout < 0 or timeout > 60 then return nil, "narrow stop timeout is invalid" end
        ok, call_err = (docker :: any):stop_container(raw.backend_ref, timeout)
    else ok, call_err = (docker :: any):remove_container(raw.backend_ref, false) end
    if not ok then return nil, tostring(call_err) end
    if before then return observation(before, forced), nil end
    local item, item_err = (docker :: any):inspect_container(raw.backend_ref)
    if type(item) ~= "table" then return nil, tostring(item_err) end
    return observation(item :: DynamicObject, forced), nil
end

function runtime.start_with(value: unknown, deps: DynamicObject) return transition(value, deps, "start", "running") end
function runtime.stop_with(value: unknown, deps: DynamicObject) return transition(value, deps, "stop", "stopped") end
function runtime.remove_with(value: unknown, deps: DynamicObject) return transition(value, deps, "remove", "destroyed") end
function runtime.production(docker_client: any): DynamicObject
    return { client = function() return docker_client.new() end }
end

return runtime
