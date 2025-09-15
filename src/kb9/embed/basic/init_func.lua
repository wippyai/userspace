local function handle(request)
    -- Basic embedder requires no initialization
    -- Just return success with empty operations
    return {
        success = true,
        ops = {}
    }
end

return { handle = handle }