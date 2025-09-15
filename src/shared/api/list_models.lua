local http = require("http")
local json = require("json")
local models = require("models")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local capability_filter = req:query("capability")
    local all_models = models.get_all()
    local formatted_models = {}

    for _, model in ipairs(all_models) do
        local should_include = false

        if capability_filter then
            if capability_filter == "embedding" then
                if model.capabilities then
                    for _, cap in ipairs(model.capabilities) do
                        if cap == "embed" then
                            should_include = true
                            break
                        end
                    end
                end
            elseif capability_filter == "generate" then
                if model.capabilities then
                    for _, cap in ipairs(model.capabilities) do
                        if cap == "generate" or cap == "tool_use" then
                            should_include = true
                            break
                        end
                    end
                end
                if not should_include and model.handlers and model.handlers.generate then
                    should_include = true
                end
                if model.capabilities then
                    for _, cap in ipairs(model.capabilities) do
                        if cap == "embed" then
                            should_include = false
                            break
                        end
                    end
                end
            else
                if model.capabilities then
                    for _, cap in ipairs(model.capabilities) do
                        if cap == capability_filter then
                            should_include = true
                            break
                        end
                    end
                end
            end
        else
            should_include = true
        end

        if should_include then
            local provider = "unknown"
            if model.handlers and model.handlers.generate then
                local provider_match = model.handlers.generate:match("wippy%.llm%.([^:]+):")
                if provider_match then
                    provider = provider_match
                end
            elseif model.handlers and model.handlers.embeddings then
                local provider_match = model.handlers.embeddings:match("wippy%.llm%.([^:]+):")
                if provider_match then
                    provider = provider_match
                end
            end

            local formatted_model = {
                name = model.name,
                title = model.title or model.name,
                description = model.description or "",
                provider = provider,
                type = model.type
            }

            if model.dimensions then
                formatted_model.dimensions = model.dimensions
            end

            if model.capabilities then
                formatted_model.capabilities = model.capabilities
            end

            table.insert(formatted_models, formatted_model)
        end
    end

    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        count = #formatted_models,
        models = formatted_models
    })
end

return {
    handler = handler
}