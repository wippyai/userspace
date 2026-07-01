local internal_registry = require("registry")

-- Create registry utilities helper module
local registry = {}

-- Get entry from registry directly, no cache
function registry.get_entry(entry_id)
    if not entry_id then
        return nil, "Entry ID is required"
    end

    -- Get entry from registry
    local raw_entry, err = internal_registry.get(entry_id)
    if not raw_entry then
        return nil, "Registry entry not found: " .. entry_id .. " (" .. (err or "unknown error") .. ")"
    end

    -- Process the entry based on its kind/type
    local entry = process_registry_entry(raw_entry)

    return entry
end

-- Process registry entries based on their kind/type
function process_registry_entry(raw_entry)
    local entry = {
        id = raw_entry.id,
        name = raw_entry.meta.name or "",
        kind = raw_entry.kind or "unknown",
        title = raw_entry.meta.title or "",
        description = raw_entry.meta.comment or "",
        tags = raw_entry.meta.tags or {},
        group = raw_entry.meta.group or {}
    }

    -- Handle different entry kinds
    if raw_entry.kind == "registry.entry" then
        if raw_entry.meta.type == "docscout.extraction_group" then
            -- Process extraction group specific data
            -- IMPORTANT: The data is in raw_entry.data not directly in raw_entry
            if raw_entry.data then
                entry.fields = raw_entry.data.fields or {}
                entry.prefetch = raw_entry.data.prefetch or {}
                entry.options = raw_entry.data.options or {}
                entry.scouting = raw_entry.data.scouting or {}
                entry.extracting = raw_entry.data.extracting or {}
            else
                entry.fields = {}
                entry.prefetch = {}
                entry.options = {}
                entry.scouting = {}
                entry.extracting = {}
            end
        else
            -- For other registry entry types, include raw data
            entry.data = raw_entry.data or {}
        end
    end

    return entry
end

-- List all registry entries with optional namespace and kind filters
function registry.list_entries(namespace, kind)
    -- Get a registry snapshot
    local snapshot, err = internal_registry.snapshot()
    if not snapshot then
        return nil, "Failed to get registry snapshot: " .. (err or "unknown error")
    end

    -- Get entries from registry
    local raw_entries
    if namespace then
        raw_entries = snapshot:namespace(namespace)
    else
        raw_entries = snapshot:entries()
    end

    -- Filter entries by kind if specified
    local entries = {}
    for _, raw_entry in ipairs(raw_entries) do
        if not kind or raw_entry.kind == kind then
            local entry = {
                id = raw_entry.id,
                name = raw_entry.meta.name or "",
                kind = raw_entry.kind or "unknown",
                title = raw_entry.meta.title or "",
                description = raw_entry.meta.comment or "",
                tags = raw_entry.meta.tags or {}
            }

            -- Add kind-specific properties
            if raw_entry.kind == "registry.entry" and raw_entry.meta.type == "docscout.extraction_group" then
                entry.field_count = raw_entry.data and raw_entry.data.fields and table.getn(raw_entry.data.fields) or 0
            end

            table.insert(entries, entry)
        end
    end

    -- Sort entries by ID
    table.sort(entries, function(a, b) return a.id < b.id end)

    return entries
end

-- Get configuration for a specific field within an extraction group
function registry.get_field_config(entry_id, field_name)
    if not entry_id then
        return nil, "Entry ID is required"
    end

    if not field_name then
        return nil, "Field name is required"
    end

    -- Get the entry
    local entry, err = registry.get_entry(entry_id)
    if not entry then
        return nil, err
    end

    -- Check if the entry has fields and the specific field exists
    if not entry.fields or not entry.fields[field_name] then
        return nil, "Field not found: " .. field_name
    end

    return entry.fields[field_name]
end

-- Get all field configs from an extraction group
function registry.get_all_fields(entry_id)
    -- Get the entry
    local entry, err = registry.get_entry(entry_id)
    if not entry then
        return nil, err
    end

    return entry.fields or {}
end

-- Format extraction results into a simplified structure
function registry.format_results(extraction_results, entry_id)
    if not extraction_results then
        return nil, "Extraction results are required"
    end

    -- Get entry if entry_id is provided (for type conversion)
    local entry = nil
    if entry_id then
        entry, _ = registry.get_entry(entry_id)
    end

    local formatted = {}

    for field_name, result in pairs(extraction_results) do
        -- Skip fields with errors
        if result.success then
            local value = result.value

            -- Convert value based on field type if entry is available
            if entry and entry.fields and entry.fields[field_name] then
                local field_type = entry.fields[field_name].type

                if field_type == "number" and type(value) == "string" then
                    value = tonumber(value) or value
                elseif field_type == "boolean" and type(value) == "string" then
                    value = value == "true" or value == "yes" or value == "1"
                end
            end

            formatted[field_name] = value
        else
            formatted[field_name] = "N/A"
        end
    end

    return formatted
end

-- Force refresh for a specific entry
function registry.refresh_entry(entry_id)
    return registry.get_entry(entry_id)
end

return registry
