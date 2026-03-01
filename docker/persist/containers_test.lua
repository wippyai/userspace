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

local function cleanup(db, id: string)
    db:execute("DELETE FROM container_logs WHERE container_id = ?", { id })
    db:execute("DELETE FROM containers WHERE id = ?", { id })
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
    end)
end

return test.run_cases(define_tests)
