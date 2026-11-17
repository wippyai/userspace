local reconcile = require("reconcile")
local test = require("test")

local function define_tests()
    -- Inspect double returning what the real client returns: the decoded body,
    -- or the diagnostic and the HTTP status (nil when the transport failed).
    local function inspecting(result: {state: table?, err: string?, status: number?})
        local docker = { inspected = {} :: {string} }
        function docker:inspect_container(id)
            table.insert(self.inspected, id)
            if result.state then
                return { Id = id, State = result.state }, nil, 200
            end
            return nil, result.err, result.status
        end
        return docker
    end

    local function no_inspect()
        local docker = {}
        function docker:inspect_container(_id)
            error("row is not inspected")
        end
        return docker
    end

    describe("Docker reconcile.needs_requeue", function()
        it("requeues a running row whose container stopped", function()
            local docker = inspecting({ state = { Running = false, ExitCode = 1 } })
            local requeue, err = reconcile.needs_requeue({ status = "running", docker_id = "id" }, docker)
            test.is_true(requeue, "running + observed stopped -> requeue")
            test.is_nil(err)
            test.eq(docker.inspected[1], "id")
        end)

        it("requeues a running row whose container is gone", function()
            local docker = inspecting({ err = "HTTP 404: No such container: id", status = 404 })
            test.is_true(reconcile.needs_requeue({ status = "running", docker_id = "id" }, docker),
                "running + 404 -> requeue")
        end)

        it("leaves a running, alive container alone", function()
            local docker = inspecting({ state = { Running = true } })
            test.is_false(reconcile.needs_requeue({ status = "running", docker_id = "id" }, docker),
                "running + alive -> skip (restart policy owns crashes)")
        end)

        it("keeps a running row when the inspect fails in transport", function()
            local docker = inspecting({ err = "context deadline exceeded" })
            local requeue, err = reconcile.needs_requeue({ status = "running", docker_id = "id" }, docker)
            test.is_false(requeue, "an unobserved container is not a vanished one")
            test.eq(err, "context deadline exceeded")
        end)

        it("keeps a running row when the daemon answers with an error status", function()
            local docker = inspecting({ err = "HTTP 500: internal server error", status = 500 })
            local requeue, err = reconcile.needs_requeue({ status = "running", docker_id = "id" }, docker)
            test.is_false(requeue, "a daemon error says nothing about the container")
            test.eq(err, "HTTP 500: internal server error")
        end)

        it("keeps a running row without a Docker identity", function()
            test.is_false(reconcile.needs_requeue({ status = "running", docker_id = "" }, no_inspect()),
                "nothing to observe -> skip")
        end)

        it("does not requeue a pending or claimed row", function()
            test.is_false(reconcile.needs_requeue({ status = "pending", docker_id = "id" }, no_inspect()), "pending -> skip")
            test.is_false(reconcile.needs_requeue({ status = "claimed", docker_id = "id" }, no_inspect()), "claimed -> skip")
        end)

        it("does not requeue a terminal (stopped/failed) row", function()
            test.is_false(reconcile.needs_requeue({ status = "stopped", docker_id = "id" }, no_inspect()), "stopped -> skip")
            test.is_false(reconcile.needs_requeue({ status = "failed", docker_id = "id" }, no_inspect()), "failed -> skip")
        end)

        it("does nothing for a nil row", function()
            test.is_false(reconcile.needs_requeue(nil, no_inspect()), "no row -> skip")
        end)
    end)

    describe("Docker reconcile.vanished", function()
        it("detects a missing running container by Docker ID", function()
            local docker = {}
            function docker:inspect_container(id)
                test.eq(id, "missing-id")
                return nil, "HTTP 404: No such container: missing-id", 404
            end

            test.is_true(reconcile.is_vanished({
                status = "running",
                docker_id = "missing-id",
            }, docker), "missing Docker object is vanished")
        end)

        it("tries the persisted name when the Docker ID is stale", function()
            local inspected = {}
            local docker = {}
            function docker:inspect_container(id)
                table.insert(inspected, id)
                if id == "stale-id" then
                    return nil, "HTTP 404: No such container: stale-id", 404
                end
                return { State = { Running = true } }, nil, 200
            end

            test.is_false(reconcile.is_vanished({
                status = "paused",
                docker_id = "stale-id",
                name = "still-here",
            }, docker), "name resolves the existing container")
            test.eq(#inspected, 2, "both identifiers inspected")
            test.eq(inspected[2], "still-here")
        end)

        it("does not treat Docker connection errors as vanished containers", function()
            local docker = {}
            function docker:inspect_container(_id)
                return nil, "connection refused"
            end

            local vanished, inspect_err = reconcile.is_vanished({ status = "running", docker_id = "id" }, docker)
            test.is_false(vanished, "temporary daemon failure preserves row")
            test.eq(inspect_err, "connection refused")
        end)

        it("does not read absence from diagnostic text without a 404 status", function()
            local docker = {}
            function docker:inspect_container(_id)
                return nil, "proxy: upstream returned HTTP 404", nil
            end

            local vanished, inspect_err = reconcile.is_vanished({ status = "running", docker_id = "id" }, docker)
            test.is_false(vanished, "only the daemon status establishes absence")
            test.eq(inspect_err, "proxy: upstream returned HTTP 404")
        end)

        it("ignores terminal and in-flight rows", function()
            local docker = {}
            function docker:inspect_container(_id)
                error("terminal/in-flight rows are not inspected")
            end

            test.is_false(reconcile.is_vanished({ status = "removed", docker_id = "id" }, docker))
            test.is_false(reconcile.is_vanished({ status = "pending", name = "future" }, docker))
        end)
    end)
end

return test.run_cases(define_tests)
