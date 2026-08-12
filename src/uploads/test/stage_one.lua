local function stage_one(params)
    local runs = ((params.metadata and params.metadata.stage_one_runs) or 0) + 1
    return { metadata = { stage_one_runs = runs } }
end

return { stage_one = stage_one }
