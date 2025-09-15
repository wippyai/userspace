local json = require("json")
local contract = require("contract")
local registry = require("registry")

-- Helper function to clean options schema for agent consumption
local function clean_options_schema(schema)
    if not schema or not schema.properties then
        return {
            type = "object",
            properties = {},
            required = {}
        }
    end

    local cleaned_properties = {}

    -- Clean each property by removing UI-specific metadata
    for prop_name, prop_def in pairs(schema.properties) do
        local cleaned_prop = {
            type = prop_def.type,
            description = prop_def.description
        }

        -- Keep essential fields only
        if prop_def.default ~= nil then
            cleaned_prop.default = prop_def.default
        end

        if prop_def.required then
            cleaned_prop.required = prop_def.required
        end

        -- Add examples for model fields to help agent
        if prop_def.type == "string" and prop_def.description and
           (string.find(prop_def.description:lower(), "model") or
            string.find(prop_def.description:lower(), "llm")) then
            if string.find(prop_def.description:lower(), "smaller") or
               string.find(prop_def.description:lower(), "enrichment") then
                cleaned_prop.example = "gpt-4o-mini"
            else
                cleaned_prop.example = "gpt-4o"
            end
        end

        cleaned_properties[prop_name] = cleaned_prop
    end

    return {
        type = "object",
        properties = cleaned_properties,
        required = schema.required or {}
    }
end

-- Helper function to extract clean implementation info
local function extract_clean_plugin_info(binding_id, contract_type)
    local entry, err = registry.get(binding_id)
    if not entry or not entry.meta or not entry.meta.kb9_plugin then
        return nil
    end

    local plugin = entry.meta.kb9_plugin

    return {
        binding_id = binding_id,
        name = plugin.name or "Unknown",
        description = plugin.description or "",
        contract_type = contract_type,
        options_schema = clean_options_schema(plugin.options_schema)
    }
end

local function handle(args)
    args = args or {}
    local filter_type = args.type or "all"

    local result = {
        success = true,
        implementations = {}
    }

    -- Discover embed implementations
    if filter_type == "embed" or filter_type == "all" then
        result.implementations.embed = {}

        local embed_bindings, err = contract.find_implementations("userspace.kb9:kb9_embed_contract")
        if embed_bindings then
            for _, binding_id in ipairs(embed_bindings) do
                local plugin_info = extract_clean_plugin_info(binding_id, "embed")
                if plugin_info then
                    table.insert(result.implementations.embed, plugin_info)
                end
            end
        else
            result.implementations.embed = {}
            result.warnings = result.warnings or {}
            table.insert(result.warnings, "Failed to discover embed implementations: " .. (err or "unknown error"))
        end
    end

    -- Discover query implementations
    if filter_type == "query" or filter_type == "all" then
        result.implementations.query = {}

        local query_bindings, err = contract.find_implementations("userspace.kb9:kb9_query_contract")
        if query_bindings then
            for _, binding_id in ipairs(query_bindings) do
                local plugin_info = extract_clean_plugin_info(binding_id, "query")
                if plugin_info then
                    table.insert(result.implementations.query, plugin_info)
                end
            end
        else
            result.implementations.query = {}
            result.warnings = result.warnings or {}
            table.insert(result.warnings, "Failed to discover query implementations: " .. (err or "unknown error"))
        end
    end

    -- Add summary counts
    local embed_count = result.implementations.embed and #result.implementations.embed or 0
    local query_count = result.implementations.query and #result.implementations.query or 0

    if filter_type == "all" then
        result.message = string.format("Found %d embed and %d query implementations", embed_count, query_count)
    elseif filter_type == "embed" then
        result.message = string.format("Found %d embed implementations", embed_count)
    elseif filter_type == "query" then
        result.message = string.format("Found %d query implementations", query_count)
    end

    return result
end

return { handle = handle }