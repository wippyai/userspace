local runtime = require("runtime")
local io = require("io")
local function fail(message: string) error("narrow Docker check failed: " .. message) end
local function fixture()
    return { Image = "sha256:" .. string.rep("a", 64), Cmd = { "/opt/bee/runtime/bin/agent" },
        User = "1000:1000", WorkingDir = "/workspace", Env = { "HOME=/state", "TMPDIR=/tmp" },
        OpenStdin = true, AttachStdin = true, AttachStdout = true, AttachStderr = true, Tty = false,
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
    local _, err = runtime.config(fixture()); if err then fail(err) end
    local privileged = fixture(); privileged.HostConfig.Privileged = true
    if runtime.config(privileged) ~= nil then fail("privileged config admitted") end
    local socket = fixture(); socket.HostConfig.Binds[1] = "/var/run/docker.sock:/docker.sock:rw"
    if runtime.config(socket) ~= nil then fail("Docker socket mount admitted") end
    local secret = fixture(); secret.Env[3] = "API_KEY=secret"
    if runtime.config(secret) ~= nil then fail("secret environment admitted") end
    local foreign = fixture(); foreign.Labels.foreign = "x"
    if runtime.config(foreign) ~= nil then fail("foreign labels admitted") end
    local calls = 0
    local running = { Id = "container-one", Config = { Labels = fixture().Labels },
        State = { Status = "running" } }
    local started, start_err = runtime.start_with({ backend_ref = "container-one" }, {
        client = function() return {
            inspect_container = function() return running end,
            start_container = function() calls = calls + 1; return nil, "already running" end,
        } end,
    })
    if start_err or not started or started.state ~= "running" or calls ~= 0 then
        fail("duplicate start was not reconciled from observed state")
    end
    local observations = 0
    local raced, race_err = runtime.start_with({ backend_ref = "container-race" }, {
        client = function() return {
            inspect_container = function()
                observations = observations + 1
                local state = observations >= 3 and "running" or "created"
                return { Id = "container-race", Config = { Labels = fixture().Labels },
                    State = { Status = state } }
            end,
            start_container = function() return nil, "already running" end,
        } end,
    })
    if race_err or not raced or raced.state ~= "running" or observations < 3 then
        fail("concurrent duplicate start was not reconciled through transition")
    end
    io.print("PASS: userspace/docker narrow contract rejects privileged, ambient, and socket-bearing agent sandboxes")
    return true
end
return { main = main }
