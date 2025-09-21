local state = {}

state._deps = {
    node = require("node")
}

local function run(args)
    local n, err = state._deps.node.new(args)
    if err then
        error(err)
    end

    -- Simply collect all available inputs
    local inputs = n:inputs()

    if next(inputs) == nil then
        return n:fail("No input data provided", "State node requires input data")
    end

    -- Collect inputs into structured object
    local collected = {}
    for key, input in pairs(inputs) do
        if key ~= "" then  -- Skip empty keys
            collected[key] = input.content
        end
    end

    -- If only one input and no meaningful key, return content directly
    if next(collected) == nil then
        for _, input in pairs(inputs) do
            return n:complete(input.content, "State collection completed")
        end
    end

    return n:complete(collected, "State collection completed")
end

state.run = run
return state