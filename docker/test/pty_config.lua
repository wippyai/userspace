local runtime = require("runtime")
local io = require("io")
local json = require("json")
local contract = require("contract")
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
                    if json.encode(actual) ~= json.encode(config) then error("create changed validated configuration") end
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
        if err then error(errors.wrap(err, "create mode " .. tostring(tty) .. " failed")) end
        if not result or result.backend_ref ~= id or result.state ~= "created" then
            error("create returned an unexpected container identity or state")
        end
        if created_calls ~= 1 or inspected_calls ~= 1 then error("create must dispatch exactly once") end
        local unsafe = fixture(tty); unsafe.HostConfig.Privileged = true
        if runtime.config(unsafe) ~= nil then error("terminal mode admitted privileged config") end
        local hostnet = fixture(tty); hostnet.HostConfig.NetworkMode = "host"
        if runtime.config(hostnet) ~= nil then error("terminal mode admitted host networking") end
        local input = fixture(tty); input.AttachStdin = false
        if runtime.config(input) ~= nil then error("terminal mode admitted detached input") end
        for _, field in ipairs({"OpenStdin", "AttachStdout", "AttachStderr"}) do
            local detached: Object = fixture(tty)
            detached[field] = false
            if runtime.config(detached) ~= nil then error("terminal mode admitted detached " .. field) end
        end
        local capabilities = fixture(tty); capabilities.HostConfig.CapDrop = {}
        if runtime.config(capabilities) ~= nil then error("terminal mode admitted retained capabilities") end
        local security = fixture(tty); security.HostConfig.SecurityOpt = {"no-new-privileges:true"}
        if runtime.config(security) ~= nil then error("terminal mode admitted missing security profiles") end
        local writable = fixture(tty); writable.HostConfig.ReadonlyRootfs = false
        if runtime.config(writable) ~= nil then error("terminal mode admitted writable root") end
        local unlimited = fixture(tty); unlimited.HostConfig.PidsLimit = 0
        if runtime.config(unlimited) ~= nil then error("terminal mode admitted unlimited tasks") end
    end
    local client_calls = 0
    local deps = {client = function() client_calls = client_calls + 1; error("invalid mode reached Docker") end}
    for _, invalid in ipairs({"true", 0, {}}) do
        local config: Object = fixture(false)
        config.Tty = invalid
        if runtime.config(config) ~= nil then error("invalid terminal mode was admitted") end
        local created, err = runtime.create_with({name = "bee-abcd", config = config}, deps)
        if created ~= nil or err == nil then error("create admitted invalid terminal mode") end
    end
    local missing: Object = fixture(false); missing.Tty = nil
    if runtime.config(missing) ~= nil then error("missing terminal mode was admitted") end
    local created, err = runtime.create_with({name = "bee-abcd", config = missing}, deps)
    if created ~= nil or err == nil or client_calls ~= 0 then error("missing mode reached Docker") end
    local definition, definition_err = contract.get("userspace.docker:narrow")
    if not definition then error(definition_err) end
    local narrow, open_err = definition:open()
    if not narrow then error(open_err) end
    for _, invalid in ipairs({"true", 0, {}}) do
        local config: Object = fixture(false)
        config.Tty = invalid
        local result, call_err = narrow:create({name = "bee-abcd", config = config})
        if result ~= nil or call_err == nil then error("contract admitted invalid terminal mode") end
        if not tostring(call_err):find("narrow Docker stdio shape is unsafe", 1, true) then error(call_err) end
    end
    local result, call_err = narrow:create({name = "bee-abcd", config = missing})
    if result ~= nil or call_err == nil then error("contract admitted missing terminal mode") end
    if not tostring(call_err):find("narrow Docker stdio shape is unsafe", 1, true) then error(call_err) end
    if narrow.release then narrow:release() end
    io.print("PASS: narrow create preserves explicit PTY or byte-stream mode with identical sandbox validation")
    return true
end
return {main = main}
