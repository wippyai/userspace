local consts = require("consts")

local reconcile = {}

-- Inspects a container and classifies the answer. Exactly one holds:
--   info     the daemon returned the container
--   absent   the daemon answered HTTP 404
--   err      nothing was observed (transport failure or daemon error status)
-- Only the HTTP status establishes absence; diagnostic text never does.
function reconcile.observe(docker, identifier: string): (table?, boolean, string?)
    local info, inspect_err, status = docker:inspect_container(identifier)
    if type(info) == "table" then
        return info, false, nil
    end
    if status == 404 then
        return nil, true, nil
    end
    return nil, false, inspect_err and tostring(inspect_err) or "container inspect returned no result"
end

-- Decide whether a declared container should be requeued during a monitor sweep.
-- A row marked running is requeued only when the daemon reports its container
-- stopped (restart retries exhausted) or gone, so the worker recreates it. An
-- unobserved container keeps its row and the inspect error is returned. Rows
-- that are in-flight (pending/claimed) or terminal (stopped/failed) are left
-- as-is (Docker's restart policy handles a normal crash; boot reset handles
-- claimed).
function reconcile.needs_requeue(row, docker): (boolean, string?)
    if not row or tostring(row.status) ~= consts.status.RUNNING then
        return false, nil
    end
    local docker_id = row.docker_id and tostring(row.docker_id) or ""
    if docker_id == "" then
        return false, nil
    end
    local info, absent, err = reconcile.observe(docker, docker_id)
    if absent then
        return true, nil
    end
    if not info then
        return false, err
    end
    local state = info.State
    return type(state) == "table" and not state.Running, nil
end

-- Check persisted Docker identifiers for a non-terminal row. A daemon error
-- leaves the row untouched; only a definitive not-found response expires it.
function reconcile.is_vanished(row, docker): (boolean, string?)
    if not row then
        return false, nil
    end
    local status = tostring(row.status)
    if status ~= consts.status.PENDING and status ~= consts.status.CLAIMED
        and status ~= consts.status.RUNNING and status ~= consts.status.PAUSED then
        return false, nil
    end

    local docker_id = row.docker_id and tostring(row.docker_id) or ""
    local identifiers = {}
    if docker_id ~= "" then
        table.insert(identifiers, docker_id)
    end
    if status ~= consts.status.PENDING and status ~= consts.status.CLAIMED
        and row.name and tostring(row.name) ~= "" and tostring(row.name) ~= docker_id then
        table.insert(identifiers, tostring(row.name))
    end
    if #identifiers == 0 then
        return false, nil
    end

    local last_err: string? = nil
    for _, identifier in ipairs(identifiers) do
        local _, missing, inspect_err = reconcile.observe(docker, identifier)
        if not missing then
            if inspect_err then
                last_err = inspect_err
                break
            end
            return false, nil
        end
    end
    if last_err then
        return false, last_err
    end
    return true, nil
end

return reconcile
