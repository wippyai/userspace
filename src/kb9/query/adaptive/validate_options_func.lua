local function handle(request)
    local options = request.options or {}

    if not options.analysis_model then
        return {
            valid = false,
            error = {
                code = "MISSING_REQUIRED_OPTION",
                message = "analysis_model is required"
            }
        }
    end

    if type(options.analysis_model) ~= "string" or options.analysis_model == "" then
        return {
            valid = false,
            error = {
                code = "INVALID_TYPE",
                message = "analysis_model must be a non-empty string"
            }
        }
    end

    if options.extra_prompt ~= nil then
        if type(options.extra_prompt) ~= "string" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "extra_prompt must be a string"
                }
            }
        end
    end

    if options.enable_reranking ~= nil then
        if type(options.enable_reranking) ~= "boolean" then
            return {
                valid = false,
                error = {
                    code = "INVALID_TYPE",
                    message = "enable_reranking must be a boolean"
                }
            }
        end
    end

    return { valid = true }
end

return { handle = handle }