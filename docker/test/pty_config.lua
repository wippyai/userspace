local runtime = require("runtime")
local io = require("io")
type Object = {[string]: unknown}
local function fixture(tty: boolean)
    return { Image = "sha256:" .. string.rep("a", 64), Cmd = { "/opt/bee/runtime/bin/agent" },
        User = "1000:1000", WorkingDir = "/workspace", Env = { "HOME=/state", "TMPDIR=/tmp" },
        OpenStdin = true, AttachStdin = true, AttachStdout = true, AttachStderr = true, Tty = tty,
        Labels = { ["bee.actor_ref"] = "actor:one", ["bee.revision_digest"] = "revision:one",
            ["bee.attempt_id"] = "attempt:one", ["bee.request_digest"] = "request:one",
            ["bee.lease_fence"] = "fence:one",
            ["bee.image_digest"] = "sha256:" .. string.rep("a", 64) },
        HostConfig = { ReadonlyRootfs = true, Privileged = false, CapDrop = { "ALL" },
            SecurityOpt = { "no-new-privileges:true", "seccomp={}", "apparmor=bee-default" },
            PidsLimit = 64, Memory = 1048576, NanoCPUs = 1000000, NetworkMode = "none",
            Binds = { "/host/work:/workspace:rw", "/host/state:/state:rw",
                "/host/runtime:/opt/bee/runtime:ro" },
            Tmpfs = { ["/tmp"] = "rw,nosuid,nodev,noexec" }, AutoRemove = false,
            ExtraHosts = {}, Devices = {} } }
end
local function main()
    for _, tty in ipairs({false, true}) do
        local config = fixture(tty)
        local created_calls, inspected_calls = 0, 0
        local id = string.rep("b", 64)
        local result, err = runtime.create_with({name = "bee-abcd", config = config}, {
            client = function() return {
                create_container = function(_, actual, options)
                    created_calls = created_calls + 1
                    if actual.Tty ~= tty then error("create changed requested terminal mode") end
                    if actual.OpenStdin ~= true or actual.AttachStdin ~= true then error("create lost input attachment") end
                    if actual.HostConfig.Privileged ~= false or actual.HostConfig.ReadonlyRootfs ~= true then error("terminal mode changed sandbox") end
                    if options.name ~= "bee-abcd" then error("create changed exact name") end
                    return {Id = id}
                end,
                inspect_container = function(_, ref)
                    inspected_calls = inspected_calls + 1
                    if ref ~= id then error("create inspected a different container") end
                    return {Id = id, Image = config.Image, Config = {Labels = config.Labels, Tty = tty}, State = {Status = "created"}}
                end,
                start_container = function() error("create must not start a container") end,
            } end,
        })
        if err or not result or result.backend_ref ~= id or result.state ~= "created" then
            error("create mode " .. tostring(tty) .. " failed: " .. tostring(err))
        end
        if created_calls ~= 1 or inspected_calls ~= 1 then error("create must dispatch exactly once") end
        local unsafe = fixture(tty); unsafe.HostConfig.Privileged = true
        if runtime.config(unsafe) ~= nil then error("terminal mode admitted privileged config") end
        local hostnet = fixture(tty); hostnet.HostConfig.NetworkMode = "host"
        if runtime.config(hostnet) ~= nil then error("terminal mode admitted host networking") end
        local input = fixture(tty); input.AttachStdin = false
        if runtime.config(input) ~= nil then error("terminal mode admitted detached input") end
    end
    for _, invalid in ipairs({"true", 0}) do
        local config: Object = fixture(false)
        config.Tty = invalid
        if runtime.config(config) ~= nil then error("invalid terminal mode was admitted") end
    end
    local missing: Object = fixture(false); missing.Tty = nil
    if runtime.config(missing) ~= nil then error("missing terminal mode was admitted") end
    io.print("PASS: narrow create preserves explicit PTY or byte-stream mode with identical sandbox validation")
    return true
end
return {main = main}
