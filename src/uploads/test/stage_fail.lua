local function stage_fail(params)
    error("stage_fail always fails")
end

return { stage_fail = stage_fail }
