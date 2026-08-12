-- Defers on the first pass (simulating "async job started"), succeeds on any
-- later pass (simulating "job result available").
local function stage_defer(params)
    local md = params.metadata or {}
    local runs = (md.stage_defer_runs or 0) + 1

    if md.defer_job then
        return { metadata = { stage_defer_runs = runs } }
    end

    return {
        defer = true,
        metadata = { stage_defer_runs = runs, defer_job = "job-123" }
    }
end

return { stage_defer = stage_defer }
