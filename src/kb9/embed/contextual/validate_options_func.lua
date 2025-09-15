local function handle(request)
    local options = request.options or {}

    -- Validate required models
    if not options.chunk_enrichment_model then
        return {
            valid = false,
            error = {
                code = "MISSING_REQUIRED_OPTION",
                message = "chunk_enrichment_model is required"
            }
        }
    end

    if not options.summary_model then
        return {
            valid = false,
            error = {
                code = "MISSING_REQUIRED_OPTION",
                message = "summary_model is required"
            }
        }
    end

    -- Validate model names are strings
    if type(options.chunk_enrichment_model) ~= "string" or options.chunk_enrichment_model == "" then
        return {
            valid = false,
            error = {
                code = "INVALID_TYPE",
                message = "chunk_enrichment_model must be a non-empty string"
            }
        }
    end

    if type(options.summary_model) ~= "string" or options.summary_model == "" then
        return {
            valid = false,
            error = {
                code = "INVALID_TYPE",
                message = "summary_model must be a non-empty string"
            }
        }
    end

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

        if options.chunk_size < 300 or options.chunk_size > 2500 then
            return {
                valid = false,
                error = {
                    code = "OUT_OF_RANGE",
                    message = "chunk_size must be between 300 and 2500 characters"
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

        if options.overlap < 0 or options.overlap > 400 then
            return {
                valid = false,
                error = {
                    code = "OUT_OF_RANGE",
                    message = "overlap must be between 0 and 400 characters"
                }
            }
        end

        -- Ensure overlap is less than chunk_size
        local chunk_size = options.chunk_size or 1000
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

    -- Validate summary_length
    if options.summary_length then
        if type(options.summary_length) ~= "number" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "summary_length must be a number"
                }
            }
        end

        if options.summary_length < 200 or options.summary_length > 2200 then
            return {
                valid = false,
                error = {
                    code = "OUT_OF_RANGE",
                    message = "summary_length must be between 200 and 2200 characters"
                }
            }
        end
    end

    -- Validate context_length
    if options.context_length then
        if type(options.context_length) ~= "number" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "context_length must be a number"
                }
            }
        end

        if options.context_length < 25 or options.context_length > 500 then
            return {
                valid = false,
                error = {
                    code = "OUT_OF_RANGE",
                    message = "context_length must be between 25 and 500 characters"
                }
            }
        end
    end

    -- Validate generate_summaries
    if options.generate_summaries ~= nil then
        if type(options.generate_summaries) ~= "boolean" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "generate_summaries must be a boolean"
                }
            }
        end
    end

    return { valid = true }
end

return { handle = handle }