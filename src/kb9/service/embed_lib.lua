local contract = require("contract")
local llm = require("llm")
local consts = require("consts")

local embed_lib = {}

local MAX_TOKENS_PER_BATCH = 8000

local contract_cache = {}

local function estimate_tokens(text)
    return math.ceil(#text / 4)
end

local function get_embed_contract(embed_binding, component_id)
    local cache_key = embed_binding .. ":" .. component_id

    if contract_cache[cache_key] then
        return contract_cache[cache_key], nil
    end

    local embed_contract_def, err = contract.get("userspace.kb9:kb9_embed_contract")
    if err then
        return nil, "Failed to get embed contract: " .. err
    end

    local embed_instance, err = embed_contract_def:open(embed_binding, {component_id = component_id})
    if err then
        return nil, "Failed to open embed contract: " .. err
    end

    contract_cache[cache_key] = embed_instance
    return embed_instance, nil
end

function embed_lib.call_embed_contract(content, content_type, metadata, embed_binding, component_id, options)
    local embed_instance, err = get_embed_contract(embed_binding, component_id)
    if err then
        return nil, err
    end

    -- Pass through the metadata and options correctly
    local embed_result, err = embed_instance:embed({
        content = content,
        content_type = content_type,
        metadata = metadata or {},
        options = options or {}
    })

    if err then
        return nil, "Embed contract failed: " .. err
    end

    if not embed_result.success then
        return nil, embed_result.error and embed_result.error.message or "Embed contract returned failure"
    end

    return embed_result.ops or {}
end

function embed_lib.call_embed_contract_for_reference(reference, metadata, embed_binding, component_id, options)
    local provider_contract, err = contract.get("userspace.contract:content_provider")
    if err then
        return nil, "Failed to get content provider contract: " .. err
    end

    local provider_instance, err = provider_contract:open(reference.binding_id, reference.context or {})
    if err then
        return nil, "Failed to open content provider: " .. err
    end

    local content_result, err = provider_instance:get_content()
    if err then
        return nil, "Failed to fetch content: " .. err
    end

    local content = content_result.content or ""
    local content_type = content_result.content_type or "text/plain"

    -- Merge metadata from content provider with passed metadata
    local combined_metadata = {}

    -- Start with content provider metadata
    if content_result.metadata then
        for k, v in pairs(content_result.metadata) do
            combined_metadata[k] = v
        end
    end

    -- Override/add with explicitly passed metadata
    if metadata then
        for k, v in pairs(metadata) do
            combined_metadata[k] = v
        end
    end

    return embed_lib.call_embed_contract(content, content_type, combined_metadata, embed_binding, component_id, options)
end

function embed_lib.generate_embeddings_for_ops(ops_list, embedding_model)
    if not ops_list or #ops_list == 0 then
        return {}
    end

    if not embedding_model then
        error("Embedding model is required")
    end

    local embedding_ops = {}
    local texts_to_embed = {}
    local node_mappings = {}

    for _, op in ipairs(ops_list) do
        if op.type == consts.COMMAND_TYPES.CREATE_NODE and op.payload.embed then
            table.insert(texts_to_embed, op.payload.embed)
            node_mappings[#texts_to_embed] = op.payload.id
        end
    end

    if #texts_to_embed == 0 then
        return embedding_ops
    end

    local batches = {}
    local batch_node_maps = {}
    local current_batch = {}
    local current_map = {}
    local current_tokens = 0

    for i, text in ipairs(texts_to_embed) do
        local text_tokens = estimate_tokens(text)

        if current_tokens + text_tokens > MAX_TOKENS_PER_BATCH and #current_batch > 0 then
            table.insert(batches, current_batch)
            table.insert(batch_node_maps, current_map)
            current_batch = {}
            current_map = {}
            current_tokens = 0
        end

        table.insert(current_batch, text)
        current_map[#current_batch] = node_mappings[i]
        current_tokens = current_tokens + text_tokens
    end

    if #current_batch > 0 then
        table.insert(batches, current_batch)
        table.insert(batch_node_maps, current_map)
    end

    -- Process each batch
    for batch_idx, batch_texts in ipairs(batches) do
        local embed_response, err = llm.embed(batch_texts, {
            model = embedding_model,
            dimensions = 512
        })

        if err then
            goto continue
        end

        if not embed_response.result then
            goto continue
        end

        for i, embedding_vector in ipairs(embed_response.result) do
            local node_id = batch_node_maps[batch_idx][i]
            if node_id and embedding_vector then
                table.insert(embedding_ops, {
                    type = consts.COMMAND_TYPES.UPSERT_EMBEDDING,
                    payload = {
                        node_id = node_id,
                        embedding = embedding_vector,
                        model_name = embedding_model,
                        embedding_type = "content"
                    }
                })
            end
        end

        ::continue::
    end

    return embedding_ops
end

function embed_lib.process_content(content, content_type, metadata, embed_binding, component_id, kb_config, options)
    local ops, err = embed_lib.call_embed_contract(content, content_type, metadata, embed_binding, component_id, options)
    if err then
        return nil, err
    end

    if not kb_config.embedding_model then
        error("Embedding model not configured")
    end

    local embedding_ops = embed_lib.generate_embeddings_for_ops(ops, kb_config.embedding_model)

    local all_ops = {}
    for _, op in ipairs(ops) do
        table.insert(all_ops, op)
    end
    for _, op in ipairs(embedding_ops) do
        table.insert(all_ops, op)
    end

    return all_ops
end

function embed_lib.process_reference(reference, metadata, embed_binding, component_id, kb_config, options)
    local ops, err = embed_lib.call_embed_contract_for_reference(reference, metadata, embed_binding, component_id, options)
    if err then
        return nil, err
    end

    if not kb_config.embedding_model then
        error("Embedding model not configured")
    end

    local embedding_ops = embed_lib.generate_embeddings_for_ops(ops, kb_config.embedding_model)

    local all_ops = {}
    for _, op in ipairs(ops) do
        table.insert(all_ops, op)
    end
    for _, op in ipairs(embedding_ops) do
        table.insert(all_ops, op)
    end

    return all_ops
end

function embed_lib.clear_cache()
    contract_cache = {}
end

return embed_lib
