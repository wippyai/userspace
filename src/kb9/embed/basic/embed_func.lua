local text = require("text")
local uuid = require("uuid")
local json = require("json")

local DOCUMENT_LEVEL = 1000
local CHUNK_LEVEL = 500

local function handle(request)
    local content = request.content
    local content_type = request.content_type or "text/plain"
    local options = request.options or {}
    local original_metadata = request.metadata or {}

    if not content or content == "" then
        return {
            success = false,
            error = {
                code = "MISSING_CONTENT",
                message = "Content is required for embedding"
            }
        }
    end

    local chunk_size = options.chunk_size or 500
    local overlap = options.overlap or 120
    local include_code_blocks = options.include_code_blocks ~= false

    local preserve_structure = true
    local min_chunk_size = math.max(30, math.floor(chunk_size * 0.1))

    local splitter, err
    if preserve_structure and (content_type == "text/markdown" or content_type == "text/html") then
        local markdown_config = {
            chunk_size = chunk_size,
            chunk_overlap = overlap,
            code_blocks = include_code_blocks,
            reference_links = true,
            heading_hierarchy = true,
            join_table_rows = false,
            keep_separator = false
        }
        splitter, err = text.splitter.markdown(markdown_config)
    else
        local recursive_config = {
            chunk_size = chunk_size,
            chunk_overlap = overlap,
            keep_separator = false
        }
        splitter, err = text.splitter.recursive(recursive_config)
    end

    if err then
        return {
            success = false,
            error = {
                code = "SPLITTER_ERROR",
                message = "Failed to create text splitter: " .. err
            }
        }
    end

    local chunks, err = splitter:split_text(content)
    if err then
        return {
            success = false,
            error = {
                code = "CHUNKING_ERROR",
                message = "Failed to split content: " .. err
            }
        }
    end

    local filtered_chunks = {}
    for i, chunk in ipairs(chunks) do
        if #chunk >= min_chunk_size then
            table.insert(filtered_chunks, chunk)
        end
    end

    if #filtered_chunks == 0 then
        return {
            success = false,
            error = {
                code = "NO_VALID_CHUNKS",
                message = "No chunks meet minimum size requirement"
            }
        }
    end

    local ops = {}
    local document_id = uuid.v7()

    local document_metadata = {}
    for k, v in pairs(original_metadata) do
        document_metadata[k] = v
    end

    document_metadata.original_length = #content
    document_metadata.chunk_count = #filtered_chunks
    document_metadata.chunking_config = {
        chunk_size = chunk_size,
        overlap = overlap,
        preserve_structure = preserve_structure,
        min_chunk_size = min_chunk_size,
        include_code_blocks = include_code_blocks
    }
    document_metadata.embedder = "basic"

    table.insert(ops, {
        type = "CREATE_NODE",
        payload = {
            id = document_id,
            node_type = "document",
            level = DOCUMENT_LEVEL,
            content = content,
            content_type = content_type,
            metadata = document_metadata
        }
    })

    for i, chunk in ipairs(filtered_chunks) do
        local chunk_id = uuid.v7()

        table.insert(ops, {
            type = "CREATE_NODE",
            payload = {
                id = chunk_id,
                parent_id = document_id,
                node_type = "chunk",
                level = CHUNK_LEVEL,
                content = chunk,
                content_type = "text/plain",
                embed = chunk,
                metadata = {
                    chunk_index = i,
                    chunk_length = #chunk,
                    embedder = "basic"
                }
            }
        })
    end

    return {
        success = true,
        ops = ops
    }
end

return { handle = handle }