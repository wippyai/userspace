local ctx = require("ctx")
local reader = require("reader")

local function handle(request)
    local query_text = request.query
    local input_vector = request.input_vector
    local limit = request.limit or 10
    local options = request.options or {}

    -- Get component_id from context (this is the kb_id)
    local component_id = ctx.get("component_id")
    if not component_id then
        return {
            success = false,
            error = {
                code = "MISSING_CONTEXT",
                message = "component_id not found in context"
            }
        }
    end

    -- Validate required inputs
    if not input_vector or type(input_vector) ~= "table" then
        return {
            success = false,
            error = {
                code = "INVALID_INPUT_VECTOR",
                message = "input_vector must be provided as an array"
            }
        }
    end

    if #input_vector ~= 512 then
        return {
            success = false,
            error = {
                code = "INVALID_VECTOR_DIMENSIONS",
                message = "input_vector must have exactly 512 dimensions"
            }
        }
    end

    -- Apply options
    local max_results = options.max_results or 20

    -- Use the smaller of limit and max_results
    local effective_limit = math.min(limit, max_results)

    -- Create reader and configure it - ONLY SEARCH CHUNKS
    local kb_reader = reader.for_kb(component_id)
        :near_vector(input_vector)
        :limit(effective_limit)
        :include_content()
        :include_metadata()

    -- Execute the search
    local search_results, err = kb_reader:all()

    if not search_results then
        return {
            success = false,
            error = {
                code = "SEARCH_FAILED",
                message = "Vector search failed: " .. (err or "unknown error")
            }
        }
    end

    -- Format results according to updated query contract
    local items = {}
    for _, node in ipairs(search_results) do
        local item = {
            id = node.id,
            content = node.content or "",
            similarity = node.similarity or 0, -- Normalized similarity score [0,1]
            node_type = node.node_type,
            path = node.path,
            parent_id = node.parent_id,
            value = node.value,
            content_type = node.content_type,
            created_at = node.created_at,
            updated_at = node.updated_at
        }

        -- Add node-specific metadata if available
        if node.metadata then
            item.metadata = node.metadata
        end

        table.insert(items, item)
    end

    return {
        success = true,
        items = items,
        count = #items
    }
end

return { handle = handle }
