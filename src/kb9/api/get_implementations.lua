local http = require("http")
local json = require("json")
local contract = require("contract")
local registry = require("registry")

local function handler()
    local res = http.response()
    if not res then
        return nil, "Failed to get HTTP response context"
    end

    local implementations_data = {
        success = true,
        implementations = {
            embed = {},
            query = {}
        }
    }

    -- Discover embed implementations
    local embed_bindings, err = contract.find_implementations("userspace.kb9:kb9_embed_contract")
    if embed_bindings then
        for _, binding_id in ipairs(embed_bindings) do
            local entry, err = registry.get(binding_id)
            if entry and entry.meta and entry.meta.kb9_plugin then
                local plugin = entry.meta.kb9_plugin
                table.insert(implementations_data.implementations.embed, {
                    id = plugin.id or binding_id,
                    name = plugin.name or "Unknown",
                    provider = plugin.provider or "Unknown",
                    description = plugin.description or "",
                    capabilities = plugin.capabilities or {},
                    options_schema = plugin.options_schema or { type = "object", properties = {}, required = {} }
                })
            end
        end
    end

    -- Discover query implementations
    local query_bindings, err = contract.find_implementations("userspace.kb9:kb9_query_contract")
    if query_bindings then
        for _, binding_id in ipairs(query_bindings) do
            local entry, err = registry.get(binding_id)
            if entry and entry.meta and entry.meta.kb9_plugin then
                local plugin = entry.meta.kb9_plugin
                table.insert(implementations_data.implementations.query, {
                    id = plugin.id or binding_id,
                    name = plugin.name or "Unknown",
                    provider = plugin.provider or "Unknown",
                    description = plugin.description or "",
                    capabilities = plugin.capabilities or {},
                    options_schema = plugin.options_schema or { type = "object", properties = {}, required = {} }
                })
            end
        end
    end

    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json(implementations_data)
end

return {
    handler = handler
}