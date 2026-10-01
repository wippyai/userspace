local contract = require("contract")
local docker_client = require("docker_client")
local env = require("env")
local io = require("io")

local function main()
    local image = env.get("WIPPY_DOCKER_PTY_IMAGE")
    local root = env.get("WIPPY_DOCKER_PTY_ROOT")
    assert(type(image) == "string" and image:match("^sha256:[0-9a-f]+$") and #image == 71, "immutable test image required")
    assert(type(root) == "string" and root:match("^/tmp/wippy%-docker%-pty%.[A-Za-z0-9]+$"), "isolated test directory required")
    local docker, client_err = docker_client.new()
    if not docker then error(client_err) end
    local definition, definition_err = contract.get("userspace.docker:narrow")
    if not definition then error(definition_err) end
    local narrow, open_err = definition:open()
    if not narrow then error(open_err) end
    local suffix = root:gsub(".", function(char) return string.format("%02x", string.byte(char)) end)

    for _, tty in ipairs({false, true}) do
        local config = {
            Image = image, Cmd = {"/bin/sh", "/opt/test/check.sh"},
            User = "1000:1000", WorkingDir = "/workspace",
            Env = {"HOME=/state", "TMPDIR=/tmp"},
            OpenStdin = true, AttachStdin = true, AttachStdout = true, AttachStderr = true, Tty = tty,
            Labels = {
                ["bee.actor_ref"] = "pty-test", ["bee.revision_digest"] = "pty-test",
                ["bee.attempt_id"] = root, ["bee.request_digest"] = "pty-test",
                ["bee.lease_fence"] = "pty-test", ["bee.image_digest"] = image,
            },
            HostConfig = {
                ReadonlyRootfs = true, Privileged = false, CapDrop = {"ALL"},
                SecurityOpt = {"no-new-privileges:true", "seccomp=runtime/default", "apparmor=docker-default"},
                PidsLimit = 64, Memory = 134217728, NanoCPUs = 250000000, NetworkMode = "none",
                Binds = {root .. "/work:/workspace:rw", root .. "/state:/state:rw", root .. "/runtime:/opt/test:ro"},
                Tmpfs = {["/tmp"] = "rw,nosuid,nodev,noexec"}, AutoRemove = false,
                ExtraHosts = {}, Devices = {},
            },
        }
        local created, create_err = narrow:create({name = "bee-" .. suffix .. (tty and "1" or "0"), config = config})
        if not created then error(create_err) end
        local id = created.backend_ref
        assert(type(id) == "string" and #id == 64 and id:match("^[0-9a-f]+$"), "exact container ID required")
        io.print("PTY_CONTAINER " .. id .. " " .. tostring(tty))
        assert(created.state == "created" and created.observed_image_digest == image, "create changed state or image")
        local inspected, inspect_err = docker:inspect_container(id)
        if not inspected then error(inspect_err) end
        assert(inspected.Id == id and inspected.State.Status == "created", "create started a container")
        assert(inspected.Config.Tty == tty, "terminal mode changed at the Docker boundary")
        assert(inspected.Config.OpenStdin and inspected.Config.AttachStdin and inspected.Config.AttachStdout and inspected.Config.AttachStderr,
            "stdio attachments changed at the Docker boundary")
        assert(inspected.HostConfig.ReadonlyRootfs and not inspected.HostConfig.Privileged, "root isolation changed")
        assert(inspected.HostConfig.NetworkMode == "none" and inspected.HostConfig.PidsLimit == 64
            and inspected.HostConfig.Memory == 134217728 and inspected.HostConfig.NanoCpus == 250000000, "resource isolation changed")
        assert(inspected.AppArmorProfile == "docker-default", "AppArmor profile changed")
        local started, start_err = narrow:start({backend_ref = id})
        if not started then error(start_err) end
        assert(started.state == "running", "start did not observe a running container")
    end
    if narrow.release then narrow:release() end
    return true
end

return {main = main}
