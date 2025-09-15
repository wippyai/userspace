local registry = require("registry")

-- Upload Type Library - For discovering and validating upload types
local upload_type = {}

-- Find an upload type by MIME type or file extension
function upload_type.find_by_mime_or_ext(mime_type, file_ext)
    if not mime_type and not file_ext then
        return nil, "Either MIME type or file extension is required"
    end

    -- Find all upload type entries
    local types, err = registry.find({
        [".kind"] = "registry.entry",
        ["meta.type"] = "upload.type"
    })

    if err then
        return nil, "Failed to find upload types: " .. err
    end

    -- Try to match by MIME type first (preferred)
    if mime_type and mime_type ~= "" then
        for _, entry in ipairs(types) do
            if entry.data and entry.data.mime_types then
                for _, mime in ipairs(entry.data.mime_types) do
                    -- Check for exact match or pattern match
                    if mime == mime_type or string.match(mime_type, mime) then
                        return entry
                    end
                end
            end
        end
    end

    -- Try to match by file extension if MIME type didn't match
    if file_ext and file_ext ~= "" then
        for _, entry in ipairs(types) do
            if entry.data and entry.data.extensions then
                for _, ext in ipairs(entry.data.extensions) do
                    -- Check for exact match (case-insensitive)
                    if string.lower(ext) == string.lower(file_ext) then
                        return entry
                    end
                end
            end
        end
    end

    return nil, "No matching upload type found"
end

-- Get a specific upload type by ID
function upload_type.get_by_id(type_id)
    if not type_id or type_id == "" then
        return nil, "Type ID is required"
    end

    -- Get the entry directly
    local entry, err = registry.get(type_id)
    if not entry then
        return nil, "Upload type not found: " .. (err or "unknown error")
    end

    -- Validate that it's an upload type
    if not entry.meta or entry.meta.type ~= "upload.type" then
        return nil, "Invalid upload type: " .. type_id
    end

    return entry
end

-- Get complete pipeline stages with all properties for a type
function upload_type.get_pipeline(type_id)
    local entry, err = upload_type.get_by_id(type_id)
    if not entry then
        return nil, err
    end

    if not entry.data or not entry.data.pipeline or #entry.data.pipeline == 0 then
        return nil, "No pipeline defined for type: " .. type_id
    end

    -- Return the entire pipeline with all properties (func, title, etc.)
    return entry.data.pipeline
end

-- For backward compatibility (returns just the function IDs)
function upload_type.get_processors(type_id)
    local pipeline, err = upload_type.get_pipeline(type_id)
    if not pipeline then
        return nil, err
    end

    -- Extract processor function IDs from the pipeline
    local processors = {}
    for _, step in ipairs(pipeline) do
        if step.func then
            table.insert(processors, step.func)
        end
    end

    if #processors == 0 then
        return nil, "No processor functions defined in pipeline for type: " .. type_id
    end

    return processors
end

-- Get all available upload types
function upload_type.list_all()
    -- Find all upload type entries
    local types, err = registry.find({
        [".kind"] = "registry.entry",
        ["meta.type"] = "upload.type"
    })

    if err then
        return nil, "Failed to list upload types: " .. err
    end

    return types
end

return upload_type
