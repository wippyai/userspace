local function handle(request)
    -- Basic vector query requires no initialization
    -- Just return success with empty operations
    return {
        success = true,
        ops = {}
    }
end

return { handle = handle }