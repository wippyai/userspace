-- Records how often it ran and the resume cursor it was handed, so a test can
-- see what the pipeline had persisted before calling it.
local function stage_two(params)
    local md = params.metadata or {}
    local cursor = md.__pipeline_cursor

    local seen = false
    if type(cursor) == "table" then
        seen = {
            index = cursor.index,
            func = cursor.func,
            state = cursor.state,
            recoveries = cursor.recoveries,
        }
    end

    return {
        metadata = {
            stage_two_runs = (md.stage_two_runs or 0) + 1,
            stage_two_saw_cursor = seen,
        },
    }
end

return { stage_two = stage_two }
