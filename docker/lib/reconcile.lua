local consts = require("consts")

local reconcile = {}

-- Decide whether a declared container should be requeued during a monitor sweep.
-- A row marked running whose container is no longer alive (removed, or restart
-- retries exhausted) is requeued so the worker recreates it. Containers that are
-- alive, in-flight (pending/claimed), or terminal (stopped/failed) are left as-is
-- (Docker's restart policy handles a normal crash; boot reset handles claimed).
function reconcile.needs_requeue(row, alive)
    if not row then
        return false
    end
    return tostring(row.status) == consts.status.RUNNING and not alive
end

return reconcile
