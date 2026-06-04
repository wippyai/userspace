local spec = require("spec")
local test = require("test")

local function define_tests()
    describe("Container Config Builder", function()

        describe("build_container_config", function()

            it("builds minimal config with image only", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.eq(result.Image, "alpine:latest")
                test.is_false(result.Tty)
                test.is_true(result.AttachStdout)
                test.is_true(result.AttachStderr)
                test.is_false(result.OpenStdin)
                test.is_false(result.AttachStdin)
                test.is_nil(result.Cmd, "no command means nil Cmd")
                test.is_nil(result.Env, "no env means nil Env")
            end)

            it("wraps command in sh -c", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    command = "echo hello",
                })
                test.not_nil(result.Cmd, "Cmd is set")
                test.eq(result.Cmd[1], "sh", "first arg is sh")
                test.eq(result.Cmd[2], "-c", "second arg is -c")
                test.eq(result.Cmd[3], "echo hello", "third arg is the command")
            end)

            it("uses raw args as Cmd against the image entrypoint", function()
                local result = spec.build_container_config({
                    image = "mcp/markitdown",
                    args = { "--http", "--port", "3001" },
                })
                test.not_nil(result.Cmd, "Cmd is set")
                test.eq(result.Cmd[1], "--http", "args passed raw, no sh -c wrap")
                test.eq(result.Cmd[2], "--port", "second arg preserved")
                test.eq(result.Cmd[3], "3001", "third arg preserved")
            end)

            it("prefers args over command when both are set", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    command = "echo hello",
                    args = { "--flag" },
                })
                test.eq(result.Cmd[1], "--flag", "args wins")
                test.eq(#result.Cmd, 1, "no sh -c wrap when args present")
            end)

            it("sets Entrypoint when provided", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    entrypoint = { "/bin/myserver" },
                    args = { "--port", "8080" },
                })
                test.not_nil(result.Entrypoint, "Entrypoint is set")
                test.eq(result.Entrypoint[1], "/bin/myserver", "entrypoint override applied")
            end)

            it("leaves Entrypoint nil by default (image default)", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    command = "echo hi",
                })
                test.is_nil(result.Entrypoint, "no entrypoint override means nil")
            end)

            it("converts env map to array format", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    env = { FOO = "bar", BAZ = "qux" },
                })
                test.not_nil(result.Env, "Env is set")
                test.eq(#result.Env, 2, "two env vars")

                local found = {}
                for _, v in ipairs(result.Env) do
                    found[v] = true
                end
                test.ok(found["FOO=bar"], "FOO=bar present")
                test.ok(found["BAZ=qux"], "BAZ=qux present")
            end)

            it("converts volumes to HostConfig.Binds", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    volumes = {
                        { host = "/host/data", container = "/data" },
                        { host = "/host/config", container = "/config", mode = "ro" },
                    },
                })
                local binds = result.HostConfig.Binds
                test.not_nil(binds, "Binds is set")
                test.eq(#binds, 2, "two binds")

                local found = {}
                for _, b in ipairs(binds) do
                    found[b] = true
                end
                test.ok(found["/host/data:/data"], "data volume present")
                test.ok(found["/host/config:/config:ro"], "config volume with ro present")
            end)

            it("sets user and work_dir", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    user = "nobody",
                    work_dir = "/app",
                })
                test.eq(result.User, "nobody")
                test.eq(result.WorkingDir, "/app")
            end)

            it("defaults user and work_dir to empty strings", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.eq(result.User, "")
                test.eq(result.WorkingDir, "")
            end)

            it("sets interactive flags", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    interactive = true,
                })
                test.is_true(result.OpenStdin)
                test.is_true(result.AttachStdin)
            end)

            it("sets memory limit in HostConfig", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    memory_limit = 536870912,
                })
                test.eq(result.HostConfig.Memory, 536870912)
            end)

            it("converts cpu_quota to NanoCPUs", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    cpu_quota = 1.5,
                })
                test.eq(result.HostConfig.NanoCPUs, 1500000000)
            end)

            it("sets AutoRemove to false", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_false(result.HostConfig.AutoRemove)
            end)

            it("includes host.docker.internal extra host", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                local extra = result.HostConfig.ExtraHosts
                test.not_nil(extra, "ExtraHosts is set")
                test.eq(#extra, 1, "one extra host")
                test.eq(extra[1], "host.docker.internal:host-gateway")
            end)

            it("omits Binds when no volumes", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_nil(result.HostConfig.Binds, "no Binds without volumes")
            end)

            it("handles empty env map", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    env = {},
                })
                test.not_nil(result.Env, "Env is set even when empty")
                test.eq(#result.Env, 0, "empty env produces empty array")
            end)

            it("handles empty volumes", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    volumes = {},
                })
                test.is_nil(result.HostConfig.Binds, "empty volumes produces no Binds")
            end)

            it("handles volume without mode", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    volumes = {
                        { host = "/data", container = "/mnt" },
                    },
                })
                local binds = result.HostConfig.Binds
                test.not_nil(binds)
                test.eq(binds[1], "/data:/mnt", "no mode suffix")
            end)

            it("handles cpu_quota rounding", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    cpu_quota = 0.25,
                })
                test.eq(result.HostConfig.NanoCPUs, 250000000)
            end)

            it("handles command with special characters", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    command = "echo 'hello world' && exit 0",
                })
                local cmd: {string} = result.Cmd :: {string}
                test.eq(cmd[3], "echo 'hello world' && exit 0")
            end)

            it("generates PortBindings for a single port", function()
                local result = spec.build_container_config({
                    image = "nginx:latest",
                    ports = {
                        { host = 8080, container = 80 },
                    },
                })
                local bindings = result.HostConfig.PortBindings
                test.not_nil(bindings, "PortBindings is set")
                test.not_nil(bindings["80/tcp"], "80/tcp binding exists")
                test.eq(bindings["80/tcp"][1].HostPort, "8080")
            end)

            it("handles multiple ports with different protocols", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    ports = {
                        { host = 8080, container = 80 },
                        { host = 5353, container = 53, protocol = "udp" },
                    },
                })
                local bindings = result.HostConfig.PortBindings
                test.not_nil(bindings, "PortBindings is set")
                test.eq(bindings["80/tcp"][1].HostPort, "8080")
                test.eq(bindings["53/udp"][1].HostPort, "5353")
            end)

            it("sets NetworkMode when network is specified", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    network = "my-network",
                })
                test.eq(result.HostConfig.NetworkMode, "my-network")
            end)

            it("combines ports and network", function()
                local result = spec.build_container_config({
                    image = "nginx:latest",
                    ports = {
                        { host = 9090, container = 80 },
                    },
                    network = "webnet",
                })
                test.eq(result.HostConfig.NetworkMode, "webnet")
                test.eq(result.HostConfig.PortBindings["80/tcp"][1].HostPort, "9090")
            end)

            it("omits PortBindings when no ports", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_nil(result.HostConfig.PortBindings, "no PortBindings without ports")
            end)

            it("omits NetworkMode when no network", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_nil(result.HostConfig.NetworkMode, "no NetworkMode without network")
            end)

            it("sets Labels on config", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    labels = { group = "test-group", env = "staging" },
                })
                test.not_nil(result.Labels)
                test.eq(result.Labels.group, "test-group")
                test.eq(result.Labels.env, "staging")
            end)

            it("uses custom extra_hosts", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    extra_hosts = { "db:10.0.0.5", "cache:10.0.0.6" },
                })
                test.eq(#result.HostConfig.ExtraHosts, 2)
                test.eq(result.HostConfig.ExtraHosts[1], "db:10.0.0.5")
                test.eq(result.HostConfig.ExtraHosts[2], "cache:10.0.0.6")
            end)

            it("defaults extra_hosts to host.docker.internal", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.eq(#result.HostConfig.ExtraHosts, 1)
                test.eq(result.HostConfig.ExtraHosts[1], "host.docker.internal:host-gateway")
            end)

            it("sets RestartPolicy", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    restart_policy = { name = "on-failure", max_retry = 5 },
                })
                test.not_nil(result.HostConfig.RestartPolicy)
                test.eq(result.HostConfig.RestartPolicy.Name, "on-failure")
                test.eq(result.HostConfig.RestartPolicy.MaximumRetryCount, 5)
            end)

            it("sets Healthcheck with intervals in nanoseconds", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    healthcheck = {
                        test = { "CMD", "curl", "-f", "http://localhost/" },
                        interval = 5,
                        timeout = 3,
                        retries = 3,
                        start_period = 10,
                    },
                })
                test.not_nil(result.Healthcheck)
                test.eq(result.Healthcheck.Test[1], "CMD")
                test.eq(result.Healthcheck.Test[2], "curl")
                test.eq(result.Healthcheck.Interval, 5e9)
                test.eq(result.Healthcheck.Timeout, 3e9)
                test.eq(result.Healthcheck.Retries, 3)
                test.eq(result.Healthcheck.StartPeriod, 10e9)
            end)

            it("sets CapAdd", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    cap_add = { "SYS_PTRACE", "NET_ADMIN" },
                })
                test.not_nil(result.HostConfig.CapAdd)
                test.eq(#result.HostConfig.CapAdd, 2)
                test.eq(result.HostConfig.CapAdd[1], "SYS_PTRACE")
            end)

            it("sets Dns", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    dns = { "8.8.8.8", "8.8.4.4" },
                })
                test.not_nil(result.HostConfig.Dns)
                test.eq(#result.HostConfig.Dns, 2)
                test.eq(result.HostConfig.Dns[1], "8.8.8.8")
            end)

            it("omits Labels when not specified", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_nil(result.Labels)
            end)

            it("omits Healthcheck when not specified", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_nil(result.Healthcheck)
            end)

            it("omits RestartPolicy when not specified", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_nil(result.HostConfig.RestartPolicy)
            end)

            it("omits CapAdd when not specified", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_nil(result.HostConfig.CapAdd)
            end)

            it("omits Dns when not specified", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                })
                test.is_nil(result.HostConfig.Dns)
            end)

            it("sets RestartPolicy with default max_retry", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    restart_policy = { name = "always" },
                })
                test.eq(result.HostConfig.RestartPolicy.Name, "always")
                test.eq(result.HostConfig.RestartPolicy.MaximumRetryCount, 0)
            end)

            it("combines all HostConfig fields", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    memory_limit = 536870912,
                    cpu_quota = 0.5,
                    network = "my-net",
                    dns = { "1.1.1.1" },
                    cap_add = { "NET_ADMIN" },
                    restart_policy = { name = "on-failure", max_retry = 2 },
                    extra_hosts = { "api:10.0.0.1" },
                })
                test.eq(result.HostConfig.Memory, 536870912)
                test.eq(result.HostConfig.NanoCPUs, 500000000)
                test.eq(result.HostConfig.NetworkMode, "my-net")
                test.eq(result.HostConfig.Dns[1], "1.1.1.1")
                test.eq(result.HostConfig.CapAdd[1], "NET_ADMIN")
                test.eq(result.HostConfig.RestartPolicy.Name, "on-failure")
                test.eq(result.HostConfig.RestartPolicy.MaximumRetryCount, 2)
                test.eq(result.HostConfig.ExtraHosts[1], "api:10.0.0.1")
            end)

            it("sets Healthcheck with only test field", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    healthcheck = { test = { "CMD-SHELL", "exit 0" } },
                })
                test.not_nil(result.Healthcheck)
                test.eq(result.Healthcheck.Test[1], "CMD-SHELL")
                test.is_nil(result.Healthcheck.Interval)
                test.is_nil(result.Healthcheck.Timeout)
            end)

            it("combines Labels and Healthcheck on config", function()
                local result = spec.build_container_config({
                    image = "alpine:latest",
                    labels = { app = "test" },
                    healthcheck = { test = { "CMD", "true" }, interval = 2 },
                })
                test.eq(result.Labels.app, "test")
                test.eq(result.Healthcheck.Interval, 2e9)
            end)
        end)

        describe("validate", function()

            it("passes with valid image", function()
                local ok, err = spec.validate({ image = "alpine:latest" })
                test.is_true(ok)
                test.is_nil(err, "no error")
            end)

            it("fails with missing image", function()
                local ok, err = spec.validate({})
                test.is_nil(ok, "nil result")
                test.not_nil(err, "error returned")
                test.contains(err, "image", "error mentions image")
            end)

            it("fails with empty image", function()
                local ok, err = spec.validate({ image = "" })
                test.is_nil(ok, "nil result")
                test.not_nil(err, "error returned")
            end)

            it("fails with nil spec", function()
                local ok, err = spec.validate(nil)
                test.is_nil(ok, "nil result")
                test.not_nil(err, "error returned")
                test.contains(err, "spec", "error mentions spec")
            end)
        end)
    end)
end

return test.run_cases(define_tests)
