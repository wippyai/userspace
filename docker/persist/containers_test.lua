local sql = require("sql")
local env = require("env")
local test = require("test")
local containers_repo = require("containers_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    local db, err = sql.get(db_id)
    if err then
        error("failed to get database: " .. tostring(err))
    end
    return db
end

local function cleanup(db, id: any)
    if not id then return end
    local cid = tostring(id)
    db:execute("DELETE FROM container_logs WHERE container_id = ?", { cid })
    db:execute("DELETE FROM containers WHERE id = ?", { cid })
end

local function define_tests()
    describe("Container Persistence", function()

        describe("create and get", function()
            it("creates container and retrieves by id", function()
                local db = get_db()
                local id, err = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "echo hello",
                })
                test.is_nil(err, "no error on create")
                test.not_nil(id, "id returned")
                assert(id)

                local c = containers_repo.get(db, id)
                test.not_nil(c, "container found")
                test.eq(c.image, "alpine:latest")
                test.eq(c.command, "echo hello")
                test.eq(c.status, "pending")

                cleanup(db, id)
                db:release()
            end)

            it("returns nil for non-existent id", function()
                local db = get_db()
                local c, err = containers_repo.get(db, "does-not-exist-12345")
                test.is_nil(c, "no container found")
                test.is_nil(err, "no error for missing container")
                db:release()
            end)

            it("creates container with all fields", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "ubuntu:22.04",
                    command = "ls -la",
                    name = "test-container",
                    labels = { group = "test" },
                    created_by = "unit-test",
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.eq(c.image, "ubuntu:22.04")
                test.eq(c.name, "test-container")
                test.not_nil(c.labels)
                test.eq(c.labels.group, "test")
                test.eq(c.created_by, "unit-test")

                cleanup(db, id)
                db:release()
            end)

            it("stores config as JSON", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "echo test",
                    env = { FOO = "bar" },
                    work_dir = "/app",
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.not_nil(c.config)
                test.eq(c.config.env.FOO, "bar")
                test.eq(c.config.work_dir, "/app")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("list", function()
            it("returns containers filtered by status", function()
                local db = get_db()
                local id1 = containers_repo.create(db, { image = "alpine:latest", command = "echo 1" })
                local id2 = containers_repo.create(db, { image = "alpine:latest", command = "echo 2" })
                assert(id1)
                assert(id2)

                containers_repo.update_status(db, id2, "running", { started_at = os.time() })

                local pending = containers_repo.list(db, { status = "pending" })
                local found = false
                for _, c in ipairs(pending) do
                    if c.id == id1 then found = true end
                    test.eq(c.status, "pending")
                end
                test.ok(found, "pending container found")

                cleanup(db, id1)
                cleanup(db, id2)
                db:release()
            end)

            it("applies limit", function()
                local db = get_db()
                local ids: {string} = {}
                for i = 1, 5 do
                    local id = containers_repo.create(db, { image = "alpine:latest", command = "echo " .. i })
                    assert(id)
                    table.insert(ids, id)
                end

                local rows = containers_repo.list(db, { limit = 2 })
                test.eq(#rows, 2, "limit applied")

                for _, id in ipairs(ids) do
                    cleanup(db, id)
                end
                db:release()
            end)
        end)

        describe("claim", function()
            it("claims pending container", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "echo test" })
                assert(id)

                local claimed = containers_repo.claim(db, id)
                test.is_true(claimed, "first claim succeeds")

                local c = containers_repo.get(db, id)
                test.eq(c.status, "claimed")

                cleanup(db, id)
                db:release()
            end)

            it("rejects double claim", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "echo test" })
                assert(id)

                containers_repo.claim(db, id)
                local second = containers_repo.claim(db, id)
                test.is_false(second, "second claim fails")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("update_status", function()
            it("updates status with fields", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "echo test" })
                assert(id)

                containers_repo.update_status(db, id, "running", {
                    docker_id = "abc123",
                    started_at = os.time(),
                })

                local c = containers_repo.get(db, id)
                test.eq(c.status, "running")
                test.eq(c.docker_id, "abc123")

                cleanup(db, id)
                db:release()
            end)

            it("records exit code and error", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "exit 1" })
                assert(id)

                containers_repo.update_status(db, id, "failed", {
                    exit_code = 1,
                    error = "non-zero exit",
                    stopped_at = os.time(),
                })

                local c = containers_repo.get(db, id)
                test.eq(c.status, "failed")
                test.eq(c.exit_code, 1)
                test.eq(c.error, "non-zero exit")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("logs", function()
            it("appends and retrieves logs", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "echo test" })
                assert(id)

                containers_repo.append_log(db, id, "stdout", "line 1")
                containers_repo.append_log(db, id, "stderr", "line 2")
                containers_repo.append_log(db, id, "stdout", "line 3")

                local logs = containers_repo.get_logs(db, id)
                test.eq(#logs, 3, "three log lines")
                test.eq(logs[1].stream, "stdout")
                test.eq(logs[1].line, "line 1")
                test.eq(logs[2].stream, "stderr")
                test.eq(logs[2].line, "line 2")
                test.eq(logs[3].stream, "stdout")
                test.eq(logs[3].line, "line 3")

                cleanup(db, id)
                db:release()
            end)

            it("logs include timestamp", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "echo test" })
                assert(id)

                containers_repo.append_log(db, id, "stdout", "with ts")
                local logs = containers_repo.get_logs(db, id)
                test.eq(#logs, 1)
                test.not_nil(logs[1].ts, "timestamp present")
                test.is_true(logs[1].ts > 0, "timestamp is positive")

                cleanup(db, id)
                db:release()
            end)

            it("get_logs respects limit", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "echo test" })
                assert(id)

                for i = 1, 10 do
                    containers_repo.append_log(db, id, "stdout", "line " .. i)
                end

                local limited = containers_repo.get_logs(db, id, 3)
                test.eq(#limited, 3, "limit applied")
                test.eq(limited[1].line, "line 1", "oldest first")

                cleanup(db, id)
                db:release()
            end)

            it("returns empty for no logs", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "echo test" })
                assert(id)

                local logs = containers_repo.get_logs(db, id)
                test.eq(#logs, 0, "no logs")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("delete", function()
            it("removes container record", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "echo test" })
                assert(id)

                local err = containers_repo.delete(db, id)
                test.is_nil(err, "no error on delete")

                local c = containers_repo.get(db, id)
                test.is_nil(c, "container gone after delete")
                db:release()
            end)

            it("returns no error for non-existent id", function()
                local db = get_db()
                local err = containers_repo.delete(db, "non-existent-id-12345")
                test.is_nil(err, "delete of non-existent is not an error")
                db:release()
            end)
        end)

        describe("group queries", function()
            it("lists containers by group_id", function()
                local db = get_db()
                local group = "__test_group_" .. tostring(os.time())
                local id1 = containers_repo.create(db, {
                    image = "alpine:latest", command = "echo 1",
                    group_id = group,
                })
                local id2 = containers_repo.create(db, {
                    image = "alpine:latest", command = "echo 2",
                    group_id = group,
                })
                local id3 = containers_repo.create(db, {
                    image = "alpine:latest", command = "echo 3",
                    group_id = group .. "_other",
                })
                assert(id1 and id2 and id3)

                local results = containers_repo.list_by_group(db, group)
                test.eq(#results, 2, "two containers in group")

                cleanup(db, id1)
                cleanup(db, id2)
                cleanup(db, id3)
                db:release()
            end)

            it("returns empty for non-matching group", function()
                local db = get_db()
                local results = containers_repo.list_by_group(db, "__test_nonexistent_group")
                test.eq(#results, 0, "no matches")
                db:release()
            end)

            it("deletes containers by group_id", function()
                local db = get_db()
                local group = "__test_delgroup_" .. tostring(os.time())
                local id1 = containers_repo.create(db, {
                    image = "alpine:latest", command = "echo 1",
                    group_id = group,
                })
                local id2 = containers_repo.create(db, {
                    image = "alpine:latest", command = "echo 2",
                    group_id = group,
                })
                local id3 = containers_repo.create(db, {
                    image = "alpine:latest", command = "echo 3",
                    group_id = group .. "_keep",
                })
                assert(id1 and id2 and id3)

                local count = containers_repo.delete_by_group(db, group)
                test.eq(count, 2, "deleted two containers")

                test.is_nil(containers_repo.get(db, id1))
                test.is_nil(containers_repo.get(db, id2))
                test.not_nil(containers_repo.get(db, id3))

                cleanup(db, id3)
                db:release()
            end)

            it("list filters by group_id", function()
                local db = get_db()
                local group = "__test_listgroup_" .. tostring(os.time())
                containers_repo.create(db, { image = "a:1", command = "a", group_id = group })
                containers_repo.create(db, { image = "b:1", command = "b", group_id = group })
                containers_repo.create(db, { image = "c:1", command = "c" })

                local filtered = containers_repo.list(db, { group_id = group })
                test.eq(#filtered, 2, "only grouped containers")

                local with_limit = containers_repo.list(db, { group_id = group, limit = 1 })
                test.eq(#with_limit, 1, "limit works with group filter")

                containers_repo.delete_by_group(db, group)
                db:release()
            end)

            it("containers without group_id not matched", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest", command = "echo test",
                })
                assert(id)

                local results = containers_repo.list_by_group(db, "anything")
                for _, r in ipairs(results) do
                    test.is_false(r.id == id, "ungrouped container not in results")
                end

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("create with all fields", function()
            it("stores health_check and restart_policy in config", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "echo test",
                    health_check = { test = { "CMD", "true" }, interval = 5, timeout = 3 },
                    restart_policy = "on-failure",
                    max_restarts = 3,
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.not_nil(c.config)
                test.eq(c.config.restart_policy, "on-failure")
                test.eq(c.config.max_restarts, 3)
                test.not_nil(c.config.health_check)
                test.eq(c.config.health_check.interval, 5)

                cleanup(db, id)
                db:release()
            end)

            it("stores callback_pid and callback_topic", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "echo test",
                    callback_pid = "test-pid-123",
                    callback_topic = "test.topic",
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.eq(c.callback_pid, "test-pid-123")
                test.eq(c.callback_topic, "test.topic")

                cleanup(db, id)
                db:release()
            end)

            it("stores custom id", function()
                local db = get_db()
                local custom_id = "__test_custom_" .. tostring(os.time())
                local id = containers_repo.create(db, {
                    id = custom_id,
                    image = "alpine:latest",
                    command = "echo test",
                })
                test.eq(id, custom_id)

                local c = containers_repo.get(db, id :: string)
                test.eq(c.id, custom_id)

                cleanup(db, id)
                db:release()
            end)

            it("stores extra_hosts, cap_add, dns in config", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "echo test",
                    extra_hosts = { "db:10.0.0.5", "cache:10.0.0.6" },
                    cap_add = { "SYS_PTRACE" },
                    dns = { "8.8.8.8" },
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.not_nil(c.config)
                test.not_nil(c.config.extra_hosts)
                test.eq(#c.config.extra_hosts, 2)
                test.eq(c.config.extra_hosts[1], "db:10.0.0.5")
                test.not_nil(c.config.cap_add)
                test.eq(c.config.cap_add[1], "SYS_PTRACE")
                test.not_nil(c.config.dns)
                test.eq(c.config.dns[1], "8.8.8.8")

                cleanup(db, id)
                db:release()
            end)

            it("stores env and volumes in config", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "echo test",
                    env = { FOO = "bar", BAZ = "qux" },
                    volumes = {{ host = "/tmp", container = "/data", mode = "ro" }},
                    network = "test-net",
                    work_dir = "/app",
                    user = "1000:1000",
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.not_nil(c.config)
                test.eq(c.config.env.FOO, "bar")
                test.eq(c.config.network, "test-net")
                test.eq(c.config.work_dir, "/app")
                test.eq(c.config.user, "1000:1000")
                test.eq(#c.config.volumes, 1)
                test.eq(c.config.volumes[1].mode, "ro")

                cleanup(db, id)
                db:release()
            end)

            it("containers without group_id not in list_by_group", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "echo test",
                })
                assert(id)

                local results = containers_repo.list_by_group(db, "anything")
                for _, r in ipairs(results) do
                    test.is_false(r.id == id, "ungrouped container not in results")
                end

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("compose flow simulation", function()
            it("creates group of containers on shared network", function()
                local db = get_db()
                local group = "__test_compose_" .. tostring(os.time())

                local id1 = containers_repo.create(db, {
                    image = "nginx:latest", command = "nginx",
                    group_id = group, network = group,
                    labels = { role = "web" },
                })
                local id2 = containers_repo.create(db, {
                    image = "postgres:16", command = "postgres",
                    group_id = group, network = group,
                    labels = { role = "db" },
                })
                local id3 = containers_repo.create(db, {
                    image = "redis:7", command = "redis-server",
                    group_id = group, network = group,
                    labels = { role = "cache" },
                })
                assert(id1 and id2 and id3)

                local group_containers = containers_repo.list_by_group(db, group)
                test.eq(#group_containers, 3, "all three in group")

                -- All share the same network
                for _, c in ipairs(group_containers) do
                    test.eq(c.config.network, group, "container on group network")
                end

                local deleted = containers_repo.delete_by_group(db, group)
                test.eq(deleted, 3, "deleted all three")

                test.eq(#containers_repo.list_by_group(db, group), 0, "group empty after delete")

                db:release()
            end)

            it("group_id stored and retrieved correctly", function()
                local db = get_db()
                local group = "__test_gid_" .. tostring(os.time())
                local id = containers_repo.create(db, {
                    image = "alpine:latest", command = "test",
                    group_id = group,
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.eq(c.group_id, group, "group_id round-trips")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("update_status edge cases", function()
            it("clears error with empty string", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                containers_repo.update_status(db, id, "failed", { error = "something broke" })
                local c = containers_repo.get(db, id)
                test.eq(c.error, "something broke")

                containers_repo.update_status(db, id, "running", { error = "" })
                local c2 = containers_repo.get(db, id)
                test.is_nil(c2.error, "error cleared to NULL")

                cleanup(db, id)
                db:release()
            end)

            it("preserves error when not specified in update", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                containers_repo.update_status(db, id, "failed", { error = "original" })
                containers_repo.update_status(db, id, "stopped", {})
                local c = containers_repo.get(db, id)
                test.eq(c.error, "original", "error preserved when not in update")
                test.eq(c.status, "stopped")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("delete cascades logs", function()
            it("removes logs when container is deleted", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                containers_repo.append_log(db, id, "stdout", "line 1")
                containers_repo.append_log(db, id, "stderr", "line 2")

                local logs = containers_repo.get_logs(db, id)
                test.eq(#logs, 2, "logs exist before delete")

                containers_repo.delete(db, id)

                local logs_after = containers_repo.get_logs(db, id)
                test.eq(#logs_after, 0, "logs gone after delete")

                db:release()
            end)

            it("delete_by_group also removes logs", function()
                local db = get_db()
                local group = "__test_logclean_" .. tostring(os.time())
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "test",
                    group_id = group,
                })
                assert(id)

                containers_repo.append_log(db, tostring(id), "stdout", "hello")
                test.eq(#containers_repo.get_logs(db, tostring(id)), 1)

                containers_repo.delete_by_group(db, group)
                test.eq(#containers_repo.get_logs(db, tostring(id)), 0, "logs cleaned by group delete")

                db:release()
            end)
        end)

        describe("list_pending decodes labels", function()
            it("returns decoded labels and config", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "test",
                    labels = { group = "__test_pending_labels" },
                    health_check = { test = { "CMD", "true" } },
                })
                assert(id)

                local pending = containers_repo.list_pending(db)
                local found = false
                for _, row in ipairs(pending) do
                    if row.id == id then
                        found = true
                        test.not_nil(row.labels, "labels decoded")
                        test.eq(row.labels.group, "__test_pending_labels")
                        test.not_nil(row.config, "config decoded")
                        test.not_nil(row.config.health_check, "health_check in config")
                    end
                end
                test.is_true(found, "pending container found")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("group_id in get and list", function()
            it("get returns group_id", function()
                local db = get_db()
                local group = "__test_getgroup_" .. tostring(os.time())
                local id = containers_repo.create(db, {
                    image = "alpine:latest", command = "test",
                    group_id = group,
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.eq(c.group_id, group)

                cleanup(db, id)
                db:release()
            end)

            it("get returns nil group_id when not set", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest", command = "test",
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.is_nil(c.group_id)

                cleanup(db, id)
                db:release()
            end)

            it("list_by_group empty for nil group_id containers", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest", command = "test",
                })
                assert(id)

                local results = containers_repo.list_by_group(db, "")
                test.eq(#results, 0)

                cleanup(db, id)
                db:release()
            end)

            it("delete_by_group cleans logs for each container", function()
                local db = get_db()
                local group = "__test_grplogs_" .. tostring(os.time())

                local id1 = containers_repo.create(db, {
                    image = "alpine:latest", command = "a",
                    group_id = group,
                })
                local id2 = containers_repo.create(db, {
                    image = "alpine:latest", command = "b",
                    group_id = group,
                })
                assert(id1 and id2)

                containers_repo.append_log(db, tostring(id1), "stdout", "log1")
                containers_repo.append_log(db, tostring(id2), "stdout", "log2")

                test.eq(#containers_repo.get_logs(db, tostring(id1)), 1)
                test.eq(#containers_repo.get_logs(db, tostring(id2)), 1)

                containers_repo.delete_by_group(db, group)

                test.eq(#containers_repo.get_logs(db, tostring(id1)), 0, "logs for id1 cleaned")
                test.eq(#containers_repo.get_logs(db, tostring(id2)), 0, "logs for id2 cleaned")

                db:release()
            end)
        end)

        describe("status edge cases", function()
            it("update_status with exit_code 0", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                containers_repo.update_status(db, tostring(id), "stopped", { exit_code = 0 })
                local c = containers_repo.get(db, id)
                test.eq(c.exit_code, 0, "exit_code 0 stored correctly")
                test.eq(c.status, "stopped")

                cleanup(db, id)
                db:release()
            end)

            it("update_status sets started_at and stopped_at", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                local now = os.time()
                containers_repo.update_status(db, tostring(id), "running", {
                    docker_id = "abc123",
                    started_at = now,
                })
                local c = containers_repo.get(db, id)
                test.eq(c.docker_id, "abc123")
                test.eq(c.started_at, now)

                containers_repo.update_status(db, tostring(id), "stopped", {
                    exit_code = 0,
                    stopped_at = now + 10,
                })
                local c2 = containers_repo.get(db, id)
                test.eq(c2.stopped_at, now + 10)

                cleanup(db, id)
                db:release()
            end)

            it("full lifecycle: pending -> claimed -> running -> paused -> running -> stopped", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                local c = containers_repo.get(db, id)
                test.eq(c.status, "pending")

                local claimed = containers_repo.claim(db, tostring(id))
                test.is_true(claimed)
                test.eq(containers_repo.get(db, id).status, "claimed")

                containers_repo.update_status(db, tostring(id), "running", {
                    docker_id = "docker-abc",
                    started_at = os.time(),
                })
                test.eq(containers_repo.get(db, id).status, "running")

                containers_repo.update_status(db, tostring(id), "paused", {})
                test.eq(containers_repo.get(db, id).status, "paused")

                containers_repo.update_status(db, tostring(id), "running", {})
                test.eq(containers_repo.get(db, id).status, "running")

                containers_repo.update_status(db, tostring(id), "stopped", {
                    exit_code = 0,
                    stopped_at = os.time(),
                })
                local final = containers_repo.get(db, id)
                test.eq(final.status, "stopped")
                test.eq(final.exit_code, 0)

                cleanup(db, id)
                db:release()
            end)

            it("claim fails on non-pending container", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                containers_repo.update_status(db, tostring(id), "running", {})
                local claimed = containers_repo.claim(db, tostring(id))
                test.is_false(claimed, "cannot claim a running container")

                cleanup(db, id)
                db:release()
            end)

            it("docker_id empty string is stored", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                containers_repo.update_status(db, tostring(id), "running", { docker_id = "" })
                local c = containers_repo.get(db, id)
                test.eq(c.docker_id, "")

                cleanup(db, id)
                db:release()
            end)

            it("duplicate id returns error", function()
                local db = get_db()
                local custom_id = "__test_dup_" .. tostring(os.time())
                local id1, err1 = containers_repo.create(db, { id = custom_id, image = "a:1", command = "a" })
                test.not_nil(id1)
                test.is_nil(err1)

                local id2, err2 = containers_repo.create(db, { id = custom_id, image = "b:1", command = "b" })
                test.is_nil(id2, "duplicate id fails")
                test.not_nil(err2, "error returned")

                cleanup(db, custom_id)
                db:release()
            end)

            it("update_status on nonexistent id is silent", function()
                local db = get_db()
                local err = containers_repo.update_status(db, "__test_nonexistent_status", "running", {})
                test.is_nil(err, "no error updating nonexistent container")
                db:release()
            end)

            it("append_log and get_logs round-trip preserves order and stream", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test" })
                assert(id)

                for i = 1, 20 do
                    local stream = (i % 2 == 0) and "stderr" or "stdout"
                    containers_repo.append_log(db, tostring(id), stream, "line-" .. i)
                end

                local logs = containers_repo.get_logs(db, tostring(id))
                test.eq(#logs, 20, "all 20 lines")
                test.eq(logs[1].line, "line-1", "first line preserved")
                test.eq(logs[1].stream, "stdout")
                test.eq(logs[20].line, "line-20", "last line preserved")
                test.eq(logs[20].stream, "stderr")

                local limited = containers_repo.get_logs(db, tostring(id), 5)
                test.eq(#limited, 5, "limit works")
                test.eq(limited[1].line, "line-1", "limit returns oldest first")

                cleanup(db, id)
                db:release()
            end)

            it("create with all optional fields nil", function()
                local db = get_db()
                local id, err = containers_repo.create(db, { image = "alpine:latest" })
                test.not_nil(id)
                test.is_nil(err)

                local c = containers_repo.get(db, id :: string)
                test.eq(c.image, "alpine:latest")
                test.is_nil(c.command)
                test.is_nil(c.name)
                test.is_nil(c.group_id)
                test.eq(c.status, "pending")

                cleanup(db, id)
                db:release()
            end)

            it("list with combined status and group_id filter", function()
                local db = get_db()
                local group = "__test_combined_" .. tostring(os.time())

                local id1 = containers_repo.create(db, { image = "a:1", command = "a", group_id = group })
                local id2 = containers_repo.create(db, { image = "b:1", command = "b", group_id = group })
                assert(id1 and id2)

                containers_repo.update_status(db, tostring(id1), "running", {})

                local running = containers_repo.list(db, { status = "running", group_id = group })
                test.eq(#running, 1)
                test.eq(running[1].id, id1)

                local pending = containers_repo.list(db, { status = "pending", group_id = group })
                test.eq(#pending, 1)
                test.eq(pending[1].id, id2)

                local all = containers_repo.list(db, { group_id = group })
                test.eq(#all, 2)

                cleanup(db, id1)
                cleanup(db, id2)
                db:release()
            end)

            it("get decodes config with arrays correctly", function()
                local db = get_db()
                local id = containers_repo.create(db, {
                    image = "alpine:latest",
                    command = "test",
                    ports = {{ host = 8080, container = 80, protocol = "tcp" }},
                    volumes = {{ host = "/src", container = "/app", mode = "ro" }},
                    extra_hosts = { "api:10.0.0.1" },
                })
                assert(id)

                local c = containers_repo.get(db, id)
                test.not_nil(c.config)
                test.eq(#c.config.ports, 1)
                test.eq(c.config.ports[1].host, 8080)
                test.eq(c.config.ports[1].container, 80)
                test.eq(#c.config.volumes, 1)
                test.eq(c.config.volumes[1].mode, "ro")
                test.eq(c.config.extra_hosts[1], "api:10.0.0.1")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("list_by_group ordering and isolation", function()
            it("returns all containers in group", function()
                local db = get_db()
                local group = "__test_order_" .. tostring(os.time())

                local id1 = containers_repo.create(db, { image = "a:1", command = "a", group_id = group })
                local id2 = containers_repo.create(db, { image = "b:1", command = "b", group_id = group })
                local id3 = containers_repo.create(db, { image = "c:1", command = "c", group_id = group })
                assert(id1 and id2 and id3)

                local results = containers_repo.list_by_group(db, group)
                test.eq(#results, 3, "all three returned")

                local ids = {}
                for _, r in ipairs(results) do ids[r.id] = true end
                test.is_true(ids[id1], "id1 present")
                test.is_true(ids[id2], "id2 present")
                test.is_true(ids[id3], "id3 present")

                containers_repo.delete_by_group(db, group)
                db:release()
            end)

            it("groups are isolated from each other", function()
                local db = get_db()
                local g1 = "__test_iso1_" .. tostring(os.time())
                local g2 = "__test_iso2_" .. tostring(os.time())

                containers_repo.create(db, { image = "a:1", command = "a", group_id = g1 })
                containers_repo.create(db, { image = "b:1", command = "b", group_id = g1 })
                containers_repo.create(db, { image = "c:1", command = "c", group_id = g2 })

                test.eq(#containers_repo.list_by_group(db, g1), 2)
                test.eq(#containers_repo.list_by_group(db, g2), 1)

                containers_repo.delete_by_group(db, g1)
                test.eq(#containers_repo.list_by_group(db, g1), 0)
                test.eq(#containers_repo.list_by_group(db, g2), 1, "other group untouched")

                containers_repo.delete_by_group(db, g2)
                db:release()
            end)

            it("delete_by_group returns 0 for empty group", function()
                local db = get_db()
                local count = containers_repo.delete_by_group(db, "__test_empty_group_" .. tostring(os.time()))
                test.eq(count, 0)
                db:release()
            end)
        end)

        describe("get_logs edge cases", function()
            it("get_logs for nonexistent container returns empty", function()
                local db = get_db()
                local logs = containers_repo.get_logs(db, "__test_no_such_container")
                test.eq(#logs, 0)
                db:release()
            end)

            it("append_log writes to any container_id", function()
                local db = get_db()
                -- Without PRAGMA foreign_keys, logs can be written to any container_id
                local orphan_id = "__test_orphan_" .. tostring(os.time())
                local err = containers_repo.append_log(db, orphan_id, "stdout", "hello")
                test.is_nil(err, "insert succeeds")

                local logs = containers_repo.get_logs(db, orphan_id)
                test.eq(#logs, 1)

                -- Clean up orphan log
                db:execute("DELETE FROM container_logs WHERE container_id = ?", { orphan_id })
                db:release()
            end)
        end)

        describe("update_name", function()
            it("updates container name", function()
                local db = get_db()
                local id = containers_repo.create(db, { image = "alpine:latest", command = "test", name = "original" })
                assert(id)

                test.eq(containers_repo.get(db, id).name, "original")

                containers_repo.update_name(db, tostring(id), "renamed")
                test.eq(containers_repo.get(db, id).name, "renamed")

                cleanup(db, id)
                db:release()
            end)
        end)

        describe("list with status_not filter", function()
            it("excludes containers with given status", function()
                local db = get_db()
                local group = "__test_statusnot_" .. tostring(os.time())

                local id1 = containers_repo.create(db, { image = "a:1", command = "a", group_id = group })
                local id2 = containers_repo.create(db, { image = "b:1", command = "b", group_id = group })
                assert(id1 and id2)

                containers_repo.update_status(db, tostring(id1), "removed", {})

                local visible = containers_repo.list(db, { group_id = group, status_not = "removed" })
                test.eq(#visible, 1)
                test.eq(visible[1].id, id2)

                cleanup(db, id1)
                cleanup(db, id2)
                db:release()
            end)
        end)
    end)
end

return test.run_cases(define_tests)
