local ctx = require("ctx")
local time = require("time")
local store = require("store")

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            description = "Error: No component context",
            updated_at = time.now():format(time.RFC3339)
        }
    end

    -- Get component info
    local component, err = store.get_component(component_id)
    if err then
        return {
            description = "Error: Failed to load component configuration",
            updated_at = time.now():format(time.RFC3339)
        }
    end

    -- Parse config to get contract info
    local embed_binding = "unknown"
    local query_binding = "unknown"

    if component.config then
        local config = component.config
        if type(config) == "string" then
            local json = require("json")
            local parsed_config, parse_err = json.decode(config)
            if not parse_err then
                config = parsed_config
            end
        end

        if type(config) == "table" then
            if config.embed_contract and config.embed_contract.binding_id then
                embed_binding = config.embed_contract.binding_id
            end
            if config.query_contract and config.query_contract.binding_id then
                query_binding = config.query_contract.binding_id
            end
        end
    end

    local description = string.format(
        "KB9 Knowledge Base - Embed: %s, Query: %s",
        embed_binding,
        query_binding
    )

    return {
        description = description,
        updated_at = component.updated_at or time.now():format(time.RFC3339)
    }
end

return { handle = handle }