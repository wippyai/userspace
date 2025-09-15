local function handle(request)
    local options = request.options or {}

    -- Validate similarity_threshold
    if options.similarity_threshold then
        if type(options.similarity_threshold) ~= "number" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "similarity_threshold must be a number"
                }
            }
        end

        if options.similarity_threshold < 0.3 or options.similarity_threshold > 0.95 then
            return {
                valid = false,
                error = {
                    code = "OUT_OF_RANGE",
                    message = "similarity_threshold must be between 0.3 and 0.95"
                }
            }
        end
    end

    -- Validate max_results
    if options.max_results then
        if type(options.max_results) ~= "number" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "max_results must be a number"
                }
            }
        end

        if options.max_results < 5 or options.max_results > 100 then
            return {
                valid = false,
                error = {
                    code = "OUT_OF_RANGE",
                    message = "max_results must be between 5 and 100"
                }
            }
        end
    end

    return { valid = true }
end

return { handle = handle }