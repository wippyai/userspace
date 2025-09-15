local ctx = require("ctx")
local json = require("json")
local store = require("store")

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            success = false,
            error = { code = "NO_CONTEXT", message = "No component context: " .. err }
        }
    end

    -- Get component from store
    local component, err = store.get_component(component_id)
    if err then
        return {
            success = false,
            error = { code = "STORE_ERROR", message = "Failed to get component: " .. err }
        }
    end

    -- Parse config JSON if needed
    local config = component.config
    if type(config) == "string" then
        local parsed_config, parse_err = json.decode(config)
        if parse_err then
            return {
                success = false,
                error = { code = "CONFIG_PARSE_ERROR", message = "Failed to parse config: " .. parse_err }
            }
        end
        config = parsed_config
    end

    -- Validate config structure
    if not config.embed_contract then
        return {
            success = false,
            error = { code = "INVALID_CONFIG", message = "Embed contract configuration not found" }
        }
    end

    if not config.query_contract then
        return {
            success = false,
            error = { code = "INVALID_CONFIG", message = "Query contract configuration not found" }
        }
    end

    return {
        success = true,
        embedding_model = config.embedding_model,
        embed_contract = config.embed_contract,
        query_contract = config.query_contract
    }
end

return { handle = handle }