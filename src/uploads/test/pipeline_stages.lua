local function bump(metadata, key)
    return ((metadata and metadata[key]) or 0) + 1
end

local function stage_one(params)
    return { metadata = { stage_one_runs = bump(params.metadata, "stage_one_runs") } }
end

-- Defers on the first pass (simulating "async job started"), succeeds on any
-- later pass (simulating "job result available").
local function stage_defer(params)
    local md = params.metadata or {}
    local runs = bump(md, "stage_defer_runs")

    if md.defer_job then
        return { metadata = { stage_defer_runs = runs } }
    end

    return {
        defer = true,
        metadata = { stage_defer_runs = runs, defer_job = "job-123" }
    }
end

local function stage_fail(params)
    error("stage_fail always fails")
end

local function stage_three(params)
    return { metadata = { stage_three_runs = bump(params.metadata, "stage_three_runs") } }
end

return {
    stage_one = stage_one,
    stage_defer = stage_defer,
    stage_fail = stage_fail,
    stage_three = stage_three,
}
