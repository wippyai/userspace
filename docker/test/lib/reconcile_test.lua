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
end

return test.run_cases(define_tests)
