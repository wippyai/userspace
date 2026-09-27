local reconcile = require("reconcile")
local test = require("test")

local function define_tests()
    describe("Docker reconcile.needs_requeue", function()
        it("requeues a running container whose process is gone", function()
            test.is_true(reconcile.needs_requeue({ status = "running" }, false),
                "running + dead -> requeue")
        end)

        it("leaves a running, alive container alone", function()
            test.is_false(reconcile.needs_requeue({ status = "running" }, true),
                "running + alive -> skip (restart policy owns crashes)")
        end)

        it("does not requeue a pending or claimed row", function()
            test.is_false(reconcile.needs_requeue({ status = "pending" }, false), "pending -> skip")
            test.is_false(reconcile.needs_requeue({ status = "claimed" }, false), "claimed -> skip")
        end)

        it("does not requeue a terminal (stopped/failed) row", function()
            test.is_false(reconcile.needs_requeue({ status = "stopped" }, false), "stopped -> skip")
            test.is_false(reconcile.needs_requeue({ status = "failed" }, false), "failed -> skip")
        end)

        it("does nothing for a nil row", function()
            test.is_false(reconcile.needs_requeue(nil, false), "no row -> skip")
        end)
    end)

    describe("Docker reconcile.vanished", function()
        it("detects a missing running container by Docker ID", function()
            local docker = {}
            function docker:inspect_container(id)
                test.eq(id, "missing-id")
                return nil, "HTTP 404: No such container: missing-id"
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
                    return nil, "HTTP 404: No such container: stale-id"
                end
                return { State = { Running = true } }, nil
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
