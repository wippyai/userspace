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

local function inspect_missing(docker, identifier: string): (boolean, string?)
    local info, inspect_err = docker:inspect_container(identifier)
    if info then
        return false, nil
    end
    local err = tostring(inspect_err or "")
    if err:find("HTTP 404", 1, true) then
        return true, nil
    end
    return false, inspect_err and tostring(inspect_err) or "container inspect returned no result"
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
        local missing, inspect_err = inspect_missing(docker, identifier)
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
