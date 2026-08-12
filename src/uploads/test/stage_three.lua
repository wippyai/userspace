local function stage_three(params)
    local runs = ((params.metadata and params.metadata.stage_three_runs) or 0) + 1
    return { metadata = { stage_three_runs = runs } }
end

return { stage_three = stage_three }
