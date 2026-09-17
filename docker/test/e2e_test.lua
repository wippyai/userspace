local env = require("env")
local test = require("test")
local time = require("time")
local docker_client = require("docker_client")
local tar = require("tar")

local function get_logs_retry(docker, container_id, opts, max_retries)
    for i = 1, max_retries or 10 do
        local raw_logs, logs_err = docker:get_logs(container_id, opts)
        if not logs_err and raw_logs then
            local lines = docker.parse_logs(raw_logs)
            if #lines > 0 then
                return lines, nil
            end
        end
        time.sleep("200ms")
    end
    return {}, "no log lines after retries"
end

local function define_tests()
    local e2e = env.get("WIPPY_E2E")
    if not e2e or e2e == "" then
        return
    end

    describe("Docker Client E2E", function()
        local docker

        before_all(function()
            local client, err = docker_client.new("/var/run/docker.sock")
            test.not_nil(client, "docker client connects: " .. tostring(err))
            docker = client
        end)

        describe("log streaming", function()
            it("delivers lines while the container runs and ends when it exits", function()
                local created, create_err = docker:create_container({
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "echo first; sleep 3; echo second >&2; exit 7" },
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                })
                test.is_nil(create_err, "container created")
                local id = created.Id
                docker:start_container(id)
                local started = time.now()

                local reader, follow_err = docker:follow_logs(id)
                test.is_nil(follow_err, "follow stream opened")

                local decoder = docker_client.new_log_decoder({ timestamps = true })
                local cursor = docker_client.new_log_cursor()
                local lines = {}
                local first_seen_after: any = nil
                while true do
                    local chunk, read_err = reader:read(65536)
                    if read_err or chunk == nil then break end
                    for _, entry in ipairs(decoder:push(chunk)) do
                        if cursor:accept(entry) then
                            table.insert(lines, entry)
                            if entry.line == "first" then
                                first_seen_after = time.now():sub(started):seconds()
                            end
                        end
                    end
                end
                reader:close()
                local ended_after = time.now():sub(started):seconds()

                test.eq(#lines, 2, "both lines streamed")
                test.eq(lines[1].line, "first")
                test.eq(lines[2].line, "second")
                test.eq(lines[2].stream, "stderr")
                test.not_nil(lines[1].ts, "timestamped")
                test.ok(first_seen_after ~= nil and first_seen_after < 2.5, "first line arrived before the container slept out")
                test.ok(ended_after >= 3, "stream stayed open until the container exited")

                local info = docker:inspect_container(id)
                test.eq(info.State.ExitCode, 7, "exit code recorded")

                -- Reopening from the last delivered timestamp replays only what was already seen.
                cursor:reconnect()
                local resumed = docker:follow_logs(id, { since = cursor:since() })
                local replay = docker_client.new_log_decoder({ timestamps = true })
                local fresh = 0
                while true do
                    local chunk = resumed:read(65536)
                    if chunk == nil then break end
                    for _, entry in ipairs(replay:push(chunk)) do
                        if cursor:accept(entry) then fresh = fresh + 1 end
                    end
                end
                resumed:close()
                test.eq(fresh, 0, "resume delivers no duplicates")

                docker:remove_container(id, true)
            end)

            it("runs a managed container through the worker and persists its logs", function()
                local handle = contract.get("userspace.docker:containers")
                test.not_nil(handle, "containers contract available")
                local c = handle:open()
                local created = c:create({
                    image = "alpine:latest",
                    command = "for i in 1 2 3 4 5; do echo line_$i; done; sleep 2; echo done >&2; exit 3",
                })
                test.is_true(created.success, "container accepted: " .. tostring(created.error))
                local id = created.id

                local container: any = nil
                for _ = 1, 120 do
                    local got = c:get({ id = id })
                    container = got and got.container
                    if container and (container.status == "stopped" or container.status == "failed") then break end
                    time.sleep("250ms")
                end
                test.not_nil(container, "container row exists")
                test.eq(container.status, "failed", "non-zero exit marks the container failed")
                test.eq(tonumber(container.exit_code), 3, "exit code persisted")

                local logs = c:logs({ id = id, tail = 3 })
                test.is_true(logs.success, "logs readable: " .. tostring(logs.error))
                test.eq(#logs.lines, 3, "tail returns the newest lines")
                test.eq(logs.lines[1].line, "line_4")
                test.eq(logs.lines[2].line, "line_5")
                test.eq(logs.lines[3].line, "done")
                test.eq(logs.lines[3].stream, "stderr")

                local all = c:logs({ id = id, limit = 100 })
                test.eq(#all.lines, 6, "every line persisted exactly once")

                c:delete({ id = id })
                if c.release then c:release() end
            end)
        end)

        describe("archive copy (put/get file)", function()
            it("round-trips a file in and out of a container, byte-exact", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "sleep 30" },
                    HostConfig = { AutoRemove = false },
                }
                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "archive test container created")
                local id = created.Id
                docker:start_container(id)
                docker:exec_container(id, "mkdir -p /copytest/nested")

                local dir = "/copytest/nested"
                for _, payload in ipairs({
                    "plain text payload",
                    string.char(0, 1, 2, 255, 254, 10, 13, 9) .. "binary-bytes",
                    string.rep("checkpoint-shard-0123456789abcdef\n", 8000),
                }) do
                    local put_ok, put_err = docker:put_archive(id, dir, tar.create({ { name = "data.bin", content = payload } }))
                    test.not_nil(put_ok, "put_archive ok: " .. tostring(put_err))

                    local tar_data, get_err = docker:get_archive(id, dir .. "/data.bin")
                    test.is_nil(get_err, "get_archive ok")
                    local content, _, is_dir = tar.read_first(tostring(tar_data))
                    test.is_false(is_dir, "file path not flagged as dir")
                    test.eq(content, payload, "copied bytes match (" .. #payload .. " bytes)")
                end

                -- get on a directory path reports a directory, never a child file
                local dtar, derr = docker:get_archive(id, dir)
                test.is_nil(derr, "get_archive on dir succeeds at the wire level")
                local _, _, dir_is = tar.read_first(tostring(dtar))
                test.is_true(dir_is, "directory path flagged as a directory")

                docker:stop_container(id, 1)
                docker:remove_container(id, true)
            end)

            it("copies files through the containers contract and honors runtime", function()
                local c = contract.get("userspace.docker:containers"):open()
                local created = c:create({
                    image = "alpine:latest",
                    command = "sleep 60",
                    runtime = "runc",
                })
                test.is_true(created.success, "container accepted: " .. tostring(created.error))
                local id = created.id

                local row: any = nil
                for _ = 1, 120 do
                    local got = c:get({ id = id })
                    row = got and got.container
                    if row and row.status == "running" and row.docker_id and row.docker_id ~= "" then break end
                    time.sleep("250ms")
                end
                test.eq(row and row.status, "running", "managed container running")
                test.eq(row.config and row.config.runtime, "runc", "runtime persisted with the container config")

                local info = docker:inspect_container(tostring(row.docker_id))
                test.eq(info.HostConfig.Runtime, "runc", "runtime passed to the daemon")

                local payload = string.char(0, 7, 255) .. string.rep("weights", 1000)
                local put = c:put_archive({ id = id, path = "/tmp/model.bin", content = payload })
                test.is_true(put.success, "put_archive: " .. tostring(put.error))
                test.eq(put.bytes, #payload)

                local got = c:get_archive({ id = id, path = "/tmp/model.bin" })
                test.is_true(got.success, "get_archive: " .. tostring(got.error))
                test.eq(got.content, payload, "contract round-trip is byte-exact")
                test.eq(got.size, #payload)

                local as_dir = c:get_archive({ id = id, path = "/tmp" })
                test.is_false(as_dir.success, "a directory is rejected")

                local clobber = c:put_archive({ id = id, path = "/tmp/model.bin/child", content = "x" })
                test.is_false(clobber.success, "writing below a file fails instead of clobbering it")

                local missing = c:put_archive({ id = "no-such-container", path = "/tmp/x", content = "x" })
                test.is_false(missing.success)

                c:delete({ id = id })
                if c.release then c:release() end
            end)
        end)

        describe("container lifecycle", function()
            it("runs a container and captures stdout/stderr", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "echo hello_e2e && echo err_e2e >&2" },
                    AttachStdout = true,
                    AttachStderr = true,
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "container created")
                test.not_nil(created, "create response returned")
                test.not_nil(created.Id, "container ID assigned")

                local container_id = created.Id

                local _, start_err = docker:start_container(container_id)
                test.is_nil(start_err, "container started")

                local wait_result, wait_err = docker:wait_container(container_id)
                test.is_nil(wait_err, "wait completed")
                test.not_nil(wait_result, "wait result returned")
                test.eq(wait_result.StatusCode, 0, "exit code is 0")

                local lines, logs_err = get_logs_retry(docker, container_id, { tail = "100" })
                test.is_nil(logs_err, "logs fetched")
                test.gt(#lines, 0, "at least one log line")

                local found_stdout = false
                local found_stderr = false
                for _, entry in ipairs(lines) do
                    if entry.line:find("hello_e2e", 1, true) then found_stdout = true end
                    if entry.stream == "stderr" and entry.line:find("err_e2e", 1, true) then found_stderr = true end
                end
                test.ok(found_stdout, "stdout contains hello_e2e")
                test.ok(found_stderr, "stderr contains err_e2e")

                local info, inspect_err = docker:inspect_container(container_id)
                test.is_nil(inspect_err, "inspect succeeded")
                test.eq(info.Id, container_id, "inspect ID matches")

                local _, remove_err = docker:remove_container(container_id, true)
                test.is_nil(remove_err, "container removed")
            end)

            it("captures non-zero exit code", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "exit 42" },
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "container created")
                local container_id = created.Id

                docker:start_container(container_id)
                local wait_result = docker:wait_container(container_id)
                test.eq(wait_result.StatusCode, 42, "exit code is 42")

                docker:remove_container(container_id, true)
            end)
        end)

        describe("port mapping", function()
            it("creates a container with port binding visible in inspect", function()
                local spec = require("spec")
                local container_config = spec.build_container_config({
                    image = "alpine:latest",
                    command = "sleep 2",
                    ports = {
                        { host = 18080, container = 80 },
                    },
                })

                local created, create_err = docker:create_container(container_config)
                test.is_nil(create_err, "container created")
                local container_id = created.Id

                local _, start_err = docker:start_container(container_id)
                test.is_nil(start_err, "container started")

                local info, inspect_err = docker:inspect_container(container_id)
                test.is_nil(inspect_err, "inspect succeeded")

                local port_bindings = info.HostConfig.PortBindings
                test.not_nil(port_bindings, "PortBindings present")
                test.not_nil(port_bindings["80/tcp"], "80/tcp binding exists")
                test.eq(port_bindings["80/tcp"][1].HostPort, "18080")

                docker:stop_container(container_id, 1)
                docker:remove_container(container_id, true)
            end)
        end)

        describe("container operations", function()
            it("restarts a running container", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sleep", "30" },
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "container created")
                local container_id = created.Id

                docker:start_container(container_id)
                time.sleep("500ms")

                local _, restart_err = docker:restart_container(container_id, 1)
                test.is_nil(restart_err, "container restarted")

                time.sleep("500ms")
                local info = docker:inspect_container(container_id)
                test.eq(info.State.Running, true, "container running after restart")

                docker:stop_container(container_id, 1)
                docker:remove_container(container_id, true)
            end)

            it("pauses and unpauses a container", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sleep", "30" },
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "container created")
                local container_id = created.Id

                docker:start_container(container_id)
                time.sleep("500ms")

                local _, pause_err = docker:pause_container(container_id)
                test.is_nil(pause_err, "container paused")

                local info = docker:inspect_container(container_id)
                test.eq(info.State.Paused, true, "container is paused")

                local _, unpause_err = docker:unpause_container(container_id)
                test.is_nil(unpause_err, "container unpaused")

                info = docker:inspect_container(container_id)
                test.eq(info.State.Paused, false, "container is unpaused")

                docker:stop_container(container_id, 1)
                docker:remove_container(container_id, true)
            end)

            it("renames a container", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sleep", "10" },
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                }

                local created, create_err = docker:create_container(config, { name = "wippy-rename-test-" .. os.time() })
                test.is_nil(create_err, "container created")
                local container_id = created.Id

                local new_name = "wippy-renamed-" .. os.time()
                local _, rename_err = docker:rename_container(container_id, new_name)
                test.is_nil(rename_err, "container renamed")

                local info = docker:inspect_container(container_id)
                test.eq(info.Name, "/" .. new_name, "container name updated")

                docker:remove_container(container_id, true)
            end)

            it("gets container stats", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sleep", "30" },
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "container created")
                local container_id = created.Id

                docker:start_container(container_id)
                time.sleep("1s")

                local stats, stats_err = docker:container_stats(container_id)
                test.is_nil(stats_err, "stats retrieved")
                test.not_nil(stats, "stats returned")
                test.not_nil(stats.cpu_stats, "cpu_stats present")
                test.not_nil(stats.memory_stats, "memory_stats present")

                docker:stop_container(container_id, 1)
                docker:remove_container(container_id, true)
            end)

            it("gets container top", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sleep", "30" },
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "container created")
                local container_id = created.Id

                docker:start_container(container_id)
                time.sleep("500ms")

                local top, top_err = docker:container_top(container_id)
                test.is_nil(top_err, "top retrieved")
                test.not_nil(top.Titles, "titles present")
                test.not_nil(top.Processes, "processes present")
                test.gt(#top.Processes, 0, "at least one process")

                docker:stop_container(container_id, 1)
                docker:remove_container(container_id, true)
            end)
        end)

        describe("networks", function()
            it("creates, inspects, lists, and removes a network", function()
                local net_name = "wippy-test-net-" .. os.time()

                local created, create_err = docker:create_network(net_name)
                test.is_nil(create_err, "network created")
                test.not_nil(created.Id, "network ID assigned")
                local net_id = created.Id

                local inspected, inspect_err = docker:inspect_network(net_id)
                test.is_nil(inspect_err, "network inspected")
                test.eq(inspected.Name, net_name, "network name matches")
                test.eq(inspected.Driver, "bridge", "default driver is bridge")

                local networks, list_err = docker:list_networks()
                test.is_nil(list_err, "networks listed")
                local found = false
                for _, n in ipairs(networks or {}) do
                    if n.Id == net_id then
                        found = true
                        break
                    end
                end
                test.ok(found, "created network appears in list")

                local _, remove_err = docker:remove_network(net_id)
                test.is_nil(remove_err, "network removed")
            end)

            it("connects and disconnects a container from a network", function()
                local net_name = "wippy-conn-test-" .. os.time()
                local net, net_err = docker:create_network(net_name)
                test.is_nil(net_err, "network created")

                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sleep", "10" },
                    Tty = false,
                    HostConfig = { AutoRemove = false },
                }
                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "container created")
                docker:start_container(created.Id)

                local _, conn_err = docker:connect_network(net.Id, created.Id)
                test.is_nil(conn_err, "container connected to network")

                local inspected = docker:inspect_network(net.Id)
                test.not_nil(inspected.Containers, "containers present in network")

                local _, disc_err = docker:disconnect_network(net.Id, created.Id)
                test.is_nil(disc_err, "container disconnected from network")

                docker:stop_container(created.Id, 1)
                docker:remove_container(created.Id, true)
                docker:remove_network(net.Id)
            end)

            it("runs two containers on the same network", function()
                local net_name = "wippy-e2e-comm-" .. os.time()
                local net, net_err = docker:create_network(net_name)
                test.is_nil(net_err, "network created")

                local spec = require("spec")
                local server_config = spec.build_container_config({
                    image = "alpine:latest",
                    command = "sleep 10",
                    network = net_name,
                })

                local server, srv_err = docker:create_container(server_config, { name = "srv-" .. os.time() })
                test.is_nil(srv_err, "server container created")
                docker:start_container(server.Id)

                local client_config = spec.build_container_config({
                    image = "alpine:latest",
                    command = "ping -c 1 -W 3 srv-" .. os.time(),
                    network = net_name,
                })

                local client_ctr, cl_err = docker:create_container(client_config)
                test.is_nil(cl_err, "client container created")
                docker:start_container(client_ctr.Id)

                local wait_result = docker:wait_container(client_ctr.Id)
                test.not_nil(wait_result, "client container finished")

                docker:stop_container(server.Id, 1)
                docker:remove_container(server.Id, true)
                docker:remove_container(client_ctr.Id, true)
                docker:remove_network(net.Id)
            end)
        end)

        describe("volumes", function()
            it("creates, inspects, lists, and removes a volume", function()
                local vol_name = "wippy-test-vol-" .. os.time()

                local created, create_err = docker:create_volume(vol_name)
                test.is_nil(create_err, "volume created")
                test.eq(created.Name, vol_name, "volume name matches")

                local inspected, inspect_err = docker:inspect_volume(vol_name)
                test.is_nil(inspect_err, "volume inspected")
                test.eq(inspected.Name, vol_name, "inspected volume name matches")
                test.not_nil(inspected.Mountpoint, "mountpoint present")

                local result, list_err = docker:list_volumes()
                test.is_nil(list_err, "volumes listed")
                local found = false
                for _, v in ipairs(result.Volumes or {}) do
                    if v.Name == vol_name then
                        found = true
                        break
                    end
                end
                test.ok(found, "created volume appears in list")

                local _, remove_err = docker:remove_volume(vol_name)
                test.is_nil(remove_err, "volume removed")
            end)

            it("creates a volume with labels", function()
                local vol_name = "wippy-label-vol-" .. os.time()
                local created, create_err = docker:create_volume(vol_name, nil, { test_label = "test_value" })
                test.is_nil(create_err, "volume created with labels")
                test.eq(created.Name, vol_name, "volume name matches")

                local inspected = docker:inspect_volume(vol_name)
                test.not_nil(inspected.Labels, "labels present")
                test.eq(inspected.Labels.test_label, "test_value", "label value matches")

                docker:remove_volume(vol_name)
            end)
        end)

        describe("system", function()
            it("gets system info", function()
                local info, err = docker:system_info()
                test.is_nil(err, "system info retrieved")
                test.not_nil(info, "info returned")
                test.not_nil(info.NCPU, "NCPU present")
                test.not_nil(info.MemTotal, "MemTotal present")
                test.not_nil(info.ServerVersion, "ServerVersion present")
            end)

            it("gets system version", function()
                local ver, err = docker:system_version()
                test.is_nil(err, "version retrieved")
                test.not_nil(ver, "version returned")
                test.not_nil(ver.Version, "Version present")
                test.not_nil(ver.ApiVersion, "ApiVersion present")
                test.not_nil(ver.Os, "Os present")
            end)

            it("gets system disk usage", function()
                local df, err = docker:system_df()
                test.is_nil(err, "disk usage retrieved")
                test.not_nil(df, "df returned")
                test.not_nil(df.Images, "Images present")
                test.not_nil(df.Containers, "Containers present")
                test.not_nil(df.Volumes, "Volumes present")
            end)
        end)

        describe("prune", function()
            it("prunes networks", function()
                local net_name = "wippy-prune-net-" .. os.time()
                docker:create_network(net_name)

                local result, err = docker:prune_networks()
                test.is_nil(err, "prune networks succeeded")
                test.not_nil(result, "prune result returned")
            end)

            it("prunes volumes", function()
                local vol_name = "wippy-prune-vol-" .. os.time()
                docker:create_volume(vol_name)

                local result, err = docker:prune_volumes()
                test.is_nil(err, "prune volumes succeeded")
                test.not_nil(result, "prune result returned")
            end)

            it("prunes containers", function()
                local result, err = docker:prune_containers()
                test.is_nil(err, "prune containers succeeded")
                test.not_nil(result, "prune result returned")
            end)

            it("prunes images", function()
                local result, err = docker:prune_images(true)
                test.is_nil(err, "prune images succeeded")
                test.not_nil(result, "prune result returned")
            end)
        end)

        describe("spec integration", function()
            it("runs a container with env and work_dir via spec", function()
                local spec = require("spec")
                local container_config = spec.build_container_config({
                    image = "alpine:latest",
                    command = "echo $MY_VAR && pwd",
                    env = { MY_VAR = "testvalue123" },
                    work_dir = "/tmp",
                })

                local created, create_err = docker:create_container(container_config)
                test.is_nil(create_err, "spec container created")
                local container_id = created.Id

                docker:start_container(container_id)
                local wait_result = docker:wait_container(container_id)
                test.eq(wait_result.StatusCode, 0, "spec container exited 0")

                local lines = get_logs_retry(docker, container_id, { tail = "100" })

                local found_var = false
                local found_dir = false
                for _, entry in ipairs(lines) do
                    if entry.line:find("testvalue123", 1, true) then found_var = true end
                    if entry.line:find("/tmp", 1, true) then found_dir = true end
                end
                test.ok(found_var, "env var MY_VAR present in output")
                test.ok(found_dir, "work_dir /tmp present in output")

                docker:remove_container(container_id, true)
            end)
        end)

        describe("exec", function()
            it("executes command in running container", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "sleep 30" },
                    AttachStdout = true,
                    AttachStderr = true,
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "exec test container created")
                local container_id = created.Id

                docker:start_container(container_id)
                time.sleep("500ms")

                local result, exec_err = docker:exec_container(container_id, "echo exec_output_test")
                test.is_nil(exec_err, "exec succeeded")
                test.not_nil(result, "exec result returned")
                test.eq(result.exit_code, 0, "exit code 0")
                test.contains(result.stdout, "exec_output_test", "stdout contains expected text")
                test.eq(result.stderr, "", "stderr is empty")

                local result2, _ = docker:exec_container(container_id, "exit 42")
                test.not_nil(result2, "exec with non-zero exit returned")
                test.eq(result2.exit_code, 42, "exit code 42")

                local result3, _ = docker:exec_container(container_id, "echo out && echo err >&2")
                test.not_nil(result3, "exec with both streams returned")
                test.contains(result3.stdout, "out", "stdout captured")
                test.contains(result3.stderr, "err", "stderr captured")

                docker:stop_container(container_id, 1)
                docker:remove_container(container_id, true)
            end)
        end)

        describe("wait", function()
            it("waits for container to finish and returns exit code", function()
                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "sleep 1 && exit 7" },
                    AttachStdout = true,
                    AttachStderr = true,
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "wait test container created")
                local container_id = created.Id

                docker:start_container(container_id)

                local result, wait_err = docker:wait_container(container_id)
                test.is_nil(wait_err, "wait succeeded")
                test.not_nil(result, "wait result returned")
                test.eq(result.StatusCode, 7, "exit code 7")

                docker:remove_container(container_id, true)
            end)
        end)

        describe("inspect", function()
            it("returns container state and network info", function()
                local net_name = "wippy-inspect-net-" .. os.time()
                docker:create_network(net_name)

                local config = {
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "sleep 30" },
                    AttachStdout = true,
                    HostConfig = { NetworkMode = net_name },
                }

                local created, create_err = docker:create_container(config)
                test.is_nil(create_err, "inspect test container created")
                local container_id = created.Id

                docker:start_container(container_id)
                time.sleep("500ms")

                local info, inspect_err = docker:inspect_container(container_id)
                test.is_nil(inspect_err, "inspect succeeded")
                test.not_nil(info, "info returned")
                test.is_true(info.State.Running, "container running")
                test.not_nil(info.NetworkSettings, "network settings present")
                test.not_nil(info.NetworkSettings.Networks[net_name], "container on expected network")

                local ip = info.NetworkSettings.Networks[net_name].IPAddress
                test.not_nil(ip, "container has IP address")

                docker:stop_container(container_id, 1)
                docker:remove_container(container_id, true)
                docker:remove_network(net_name)
            end)
        end)

        describe("healthcheck", function()
            it("reports health status via inspect", function()
                local spec = require("spec")
                local container_config = spec.build_container_config({
                    image = "alpine:latest",
                    command = "sleep 30",
                    healthcheck = {
                        test = { "CMD-SHELL", "true" },
                        interval = 1,
                        timeout = 1,
                        retries = 3,
                        start_period = 0,
                    },
                })

                local created, create_err = docker:create_container(container_config)
                test.is_nil(create_err, "healthcheck container created")
                local container_id = created.Id

                docker:start_container(container_id)

                local healthy = false
                for _ = 1, 20 do
                    time.sleep("500ms")
                    local info = docker:inspect_container(container_id)
                    if info and info.State and info.State.Health then
                        if info.State.Health.Status == "healthy" then
                            healthy = true
                            break
                        end
                    end
                end

                test.is_true(healthy, "container became healthy")

                docker:stop_container(container_id, 1)
                docker:remove_container(container_id, true)
            end)
        end)

        describe("compose with auto-network", function()
            it("creates containers on isolated network that can communicate", function()
                local net_name = "wippy-compose-net-" .. os.time()

                -- Create two containers: a server and a client
                local server_config = {
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "sleep 30" },
                    AttachStdout = true,
                }

                docker:create_network(net_name)

                local server, s_err = docker:create_container(server_config, { name = "wippy-compose-srv-" .. os.time() })
                test.is_nil(s_err, "server created")
                docker:start_container(server.Id)

                -- Attach the server to the compose network under an alias so DNS resolves it
                local _, connect_err = docker:connect_network(net_name, server.Id, { "test-server" })
                test.is_nil(connect_err, "server connected to network with alias")
                time.sleep("500ms")

                -- Client pings server by alias
                local client_config = {
                    Image = "alpine:latest",
                    Cmd = { "sh", "-c", "ping -c 1 -W 3 test-server" },
                    AttachStdout = true,
                    HostConfig = { NetworkMode = net_name },
                }

                local client, c_err = docker:create_container(client_config)
                test.is_nil(c_err, "client created")
                docker:start_container(client.Id)

                local wait_result = docker:wait_container(client.Id)
                test.eq(wait_result.StatusCode, 0, "client pinged server by alias")

                docker:stop_container(server.Id, 1)
                docker:remove_container(server.Id, true)
                docker:remove_container(client.Id, true)
                docker:remove_network(net_name)
            end)
        end)
    end)
end

return test.run_cases(define_tests)
