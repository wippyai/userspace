local function handle(request)
    local options = request.options or {}

    -- Validate chunk_size
    if options.chunk_size then
        if type(options.chunk_size) ~= "number" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "chunk_size must be a number"
                }
            }
        end

        if options.chunk_size < 100 or options.chunk_size > 2000 then
            return {
                valid = false,
                error = {
                    code = "OUT_OF_RANGE",
                    message = "chunk_size must be between 100 and 2000 characters"
                }
            }
        end
    end

    -- Validate overlap
    if options.overlap then
        if type(options.overlap) ~= "number" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "overlap must be a number"
                }
            }
        end

        if options.overlap < 0 or options.overlap > 300 then
            return {
                valid = false,
                error = {
                    code = "OUT_OF_RANGE",
                    message = "overlap must be between 0 and 300 characters"
                }
            }
        end

        -- Ensure overlap is less than chunk_size
        local chunk_size = options.chunk_size or 500
        if options.overlap >= chunk_size then
            return {
                valid = false,
                error = {
                    code = "INVALID_CONFIGURATION",
                    message = "overlap must be less than chunk_size"
                }
            }
        end
    end

    return { valid = true }
end

return { handle = handle }