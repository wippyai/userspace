local text = require("text")
local uuid = require("uuid")
local json = require("json")
local llm = require("llm")
local prompt = require("prompt")
local compress = require("compress")

---------------------------
-- CONSTANTS AND CONFIGURATION
---------------------------

local DEFAULT_WORKER_POOL_SIZE = 16
local MAX_WORKER_POOL_SIZE = 16
local MIN_WORKER_POOL_SIZE = 1
local CACHE_WARMUP_RETRIES = 3

local MAX_PRE_SUMMARY_TOKENS = 8000
local MIN_PRE_SUMMARY_TOKENS = 1000
local CHARS_PER_TOKEN_ESTIMATE = 4

local PRE_SUMMARY_SMALL_DOC_RATIO = 0.6
local PRE_SUMMARY_LARGE_DOC_RATIO = 0.3

local CONTEXT_GENERATION_TEMPERATURE = 0.1
local PRE_SUMMARY_TEMPERATURE = 0.2
local TITLE_GENERATION_TEMPERATURE = 0.1

local MAX_TITLE_LENGTH = 120
local MIN_TITLE_LENGTH = 10

-- PROMPT TEMPLATES
local PRE_SUMMARY_SYSTEM_PROMPT = [[You are an expert at creating structured document summaries for chunk contextualization.

Create a comprehensive but concise summary that will be used to provide context for individual document chunks. Include:

1. Document type, source, and metadata
2. Key entities (companies, products, people, dates, locations)
3. Main sections and topic structure
4. Domain/industry context and terminology
5. Time period, scope, and important relationships
6. Critical facts and figures that chunks might reference

Keep the summary under %d tokens but comprehensive enough that any chunk from this document can be properly contextualized.

Return ONLY the structured summary, nothing else.]]

local PRE_SUMMARY_USER_PROMPT = [[Document content:

%s]]

local CONTEXTUAL_ENRICHMENT_SYSTEM_PROMPT = [[You are an expert at providing succinct contextual information for text chunks to improve search retrieval.

Given a document and a specific chunk from that document, provide brief context that situates this chunk within the overall document for the purposes of improving search retrieval of the chunk.

Focus on:
- What document/section this chunk is from
- Key entities, names, dates, or identifiers mentioned in surrounding context
- The specific topic or concept being discussed
- Any critical context needed to understand this chunk

Keep it under %d characters. Answer only with the succinct context and nothing else.]]

local TITLE_GENERATION_SYSTEM_PROMPT = [[You are an expert at creating formal, descriptive document titles for catalogue records.

Create a professional, descriptive title that clearly identifies the document's content and purpose. The title should:
1. Be concise but comprehensive (maximum %d characters)
2. Use formal, professional language appropriate for a document catalogue
3. Include key subject matter, document type, or primary focus
4. Avoid generic phrases like "Document about" or "Information on"
5. Be specific enough to distinguish this document from others
6. Use standard catalogue/academic title conventions

Return ONLY the title, nothing else.]]

local TITLE_GENERATION_USER_PROMPT = [[Based on this document summary, create a formal catalogue title:

%s]]

---------------------------
-- UTILITY FUNCTIONS
---------------------------

local function calculate_worker_pool_size(chunk_count, max_workers)
    max_workers = max_workers or DEFAULT_WORKER_POOL_SIZE
    max_workers = math.min(max_workers, MAX_WORKER_POOL_SIZE)
    max_workers = math.max(max_workers, MIN_WORKER_POOL_SIZE)

    if chunk_count <= 1 then
        return 1
    elseif chunk_count <= 4 then
        return math.min(4, max_workers)
    elseif chunk_count <= 8 then
        return math.min(8, max_workers)
    elseif chunk_count <= 16 then
        return math.min(12, max_workers)
    else
        return max_workers
    end
end

local function calculate_pre_summary_size(content_length)
    local estimated_tokens = math.ceil(content_length / CHARS_PER_TOKEN_ESTIMATE)

    if estimated_tokens < MIN_PRE_SUMMARY_TOKENS * 2 then
        return math.max(MIN_PRE_SUMMARY_TOKENS, math.floor(estimated_tokens * PRE_SUMMARY_SMALL_DOC_RATIO))
    end

    local target_tokens = math.min(MAX_PRE_SUMMARY_TOKENS, math.floor(estimated_tokens * PRE_SUMMARY_LARGE_DOC_RATIO))
    return math.max(MIN_PRE_SUMMARY_TOKENS, target_tokens)
end

---------------------------
-- CONTENT GENERATION FUNCTIONS
---------------------------

local function generate_document_title(pre_summary, summary_model, title_prompt_tip)
    local title_prompt = prompt.new()

    local system_prompt = string.format(TITLE_GENERATION_SYSTEM_PROMPT, MAX_TITLE_LENGTH)
    if title_prompt_tip and title_prompt_tip ~= "" then
        system_prompt = system_prompt .. "\n\nAdditional instruction: " .. title_prompt_tip
    end

    title_prompt:add_system(system_prompt)
    title_prompt:add_user(string.format(TITLE_GENERATION_USER_PROMPT, pre_summary))

    local title_response, err = llm.generate(title_prompt, {
        model = summary_model,
        temperature = TITLE_GENERATION_TEMPERATURE,
        max_tokens = math.ceil(MAX_TITLE_LENGTH / CHARS_PER_TOKEN_ESTIMATE)
    })

    if err then
        return nil, err
    end

    local title = title_response.result or ""
    title = title:gsub("^%s+", ""):gsub("%s+$", "")

    if #title < MIN_TITLE_LENGTH then
        return "Document", nil
    end

    if #title > MAX_TITLE_LENGTH then
        title = title:sub(1, MAX_TITLE_LENGTH):gsub("%s+[^%s]*$", "")
    end

    return title, nil
end

local function generate_pre_summary(content, summary_model, content_length)
    local target_tokens = calculate_pre_summary_size(content_length)

    local pre_summary_prompt = prompt.new()
    pre_summary_prompt:add_system(string.format(PRE_SUMMARY_SYSTEM_PROMPT, target_tokens))
    pre_summary_prompt:add_user(string.format(PRE_SUMMARY_USER_PROMPT, content))

    local pre_summary_response, err = llm.generate(pre_summary_prompt, {
        model = summary_model,
        temperature = PRE_SUMMARY_TEMPERATURE,
        max_tokens = target_tokens
    })

    if err then
        return nil, err
    end

    local pre_summary = pre_summary_response.result or ""
    pre_summary = pre_summary:gsub("^%s+", ""):gsub("%s+$", "")

    return pre_summary, nil
end

local function generate_chunk_context(pre_summary, chunk, chunk_enrichment_model, context_length, use_cache)
    local context_prompt = prompt.new()
    context_prompt:add_system(string.format(CONTEXTUAL_ENRICHMENT_SYSTEM_PROMPT, context_length))

    if use_cache then
        context_prompt:add_user(string.format([[<document_summary>
%s
</document_summary>]], pre_summary))

        context_prompt:add_cache_marker("document_summary_context")

        context_prompt:add_user(string.format([[<chunk>
%s
</chunk>

Provide contextual information for this chunk:]], chunk))
    else
        context_prompt:add_user(string.format([[<document>
%s
</document>

Here is the chunk we want to situate within the whole document:
<chunk>
%s
</chunk>

Please give a short succinct context to situate this chunk within the overall document for the purposes of improving search retrieval of the chunk. Answer only with the succinct context and nothing else.]], pre_summary, chunk))
    end

    local context_response, err = llm.generate(context_prompt, {
        model = chunk_enrichment_model,
        temperature = CONTEXT_GENERATION_TEMPERATURE,
        max_tokens = math.ceil(context_length / CHARS_PER_TOKEN_ESTIMATE)
    })

    if err then
        return nil, err
    end

    local contextual_info = context_response.result or ""
    contextual_info = contextual_info:gsub("^%s+", ""):gsub("%s+$", "")

    return contextual_info, nil
end

---------------------------
-- CHUNK MERGING LOGIC
---------------------------

local function identify_small_sequences(chunks, min_chunk_size)
    local sequences = {}
    local i = 1
    while i <= #chunks do
        if #chunks[i] < min_chunk_size then
            local start_idx = i
            local total_size = 0
            while i <= #chunks and #chunks[i] < min_chunk_size do
                total_size = total_size + #chunks[i]
                i = i + 1
            end
            local end_idx = i - 1
            local context = "between"
            if start_idx == 1 then context = "at_start" elseif end_idx == #chunks then context = "at_end" end
            table.insert(sequences, { start_idx = start_idx, end_idx = end_idx, total_size = total_size, context = context })
        else
            i = i + 1
        end
    end
    return sequences
end

local function adaptive_split_sequence(sequence_chunks, max_merged_size)
    local total_size = 0
    for _, chunk in ipairs(sequence_chunks) do total_size = total_size + #chunk end
    if total_size <= max_merged_size then return {table.concat(sequence_chunks, "\n\n")} end
    local num_chunks = math.ceil(total_size / max_merged_size)
    local target_size = math.ceil(total_size / num_chunks)
    local result = {}
    local current_chunk = {}
    local current_size = 0
    for _, chunk in ipairs(sequence_chunks) do
        if current_size + #chunk > target_size and #current_chunk > 0 then
            table.insert(result, table.concat(current_chunk, "\n\n"))
            current_chunk = {chunk}
            current_size = #chunk
        else
            table.insert(current_chunk, chunk)
            current_size = current_size + #chunk
        end
    end
    if #current_chunk > 0 then table.insert(result, table.concat(current_chunk, "\n\n")) end
    return result
end

local function merge_small_chunks(chunks, options)
    local chunk_size = options.chunk_size or 1000
    local min_chunk_size = options.min_chunk_size or math.floor(chunk_size * 0.25)
    local max_merged_size = options.max_merged_size or math.floor(chunk_size * 1.5)
    local enable_merging = options.enable_chunk_merging ~= false
    if not enable_merging or #chunks <= 1 then return chunks end

    local small_sequences = identify_small_sequences(chunks, min_chunk_size)
    if #small_sequences == 0 then
        print("No small chunks found, using original chunks")
        return chunks
    end

    print(string.format("Found %d small chunk sequences to process", #small_sequences))

    local final_result = {}
    local last_processed_idx = 0
    for _, seq in ipairs(small_sequences) do
        for i = last_processed_idx + 1, seq.start_idx - 1 do
            table.insert(final_result, chunks[i])
        end
        local sequence_chunks = {}
        for i = seq.start_idx, seq.end_idx do
            table.insert(sequence_chunks, chunks[i])
        end
        local new_chunks_for_sequence = nil
        if seq.context == "at_start" then
            new_chunks_for_sequence = adaptive_split_sequence(sequence_chunks, max_merged_size)
        elseif seq.context == "at_end" then
            if #final_result > 0 then
                final_result[#final_result] = final_result[#final_result] .. "\n\n" .. table.concat(sequence_chunks, "\n\n")
            else
                new_chunks_for_sequence = adaptive_split_sequence(sequence_chunks, max_merged_size)
            end
        else -- "between"
            if seq.total_size <= chunk_size and #final_result > 0 then
                final_result[#final_result] = final_result[#final_result] .. "\n\n" .. table.concat(sequence_chunks, "\n\n")
            else
                new_chunks_for_sequence = adaptive_split_sequence(sequence_chunks, max_merged_size)
            end
        end
        if new_chunks_for_sequence then
            for _, new_chunk in ipairs(new_chunks_for_sequence) do
                table.insert(final_result, new_chunk)
            end
        end
        last_processed_idx = seq.end_idx
    end
    for i = last_processed_idx + 1, #chunks do
        table.insert(final_result, chunks[i])
    end

    print(string.format("Chunk merging complete: %d → %d chunks", #chunks, #final_result))
    return final_result
end


---------------------------
-- CONCURRENT PROCESSING
---------------------------

local function chunk_worker(worker_id, work_ch, result_ch, done_ch, pre_summary, chunk_enrichment_model, context_length)
    while true do
        local work, ok = work_ch:receive()
        if not ok then
            break -- Channel is closed, no more work
        end

        local success, result_or_err = pcall(function()
            local contextual_info, err = generate_chunk_context(pre_summary, work.chunk, chunk_enrichment_model, context_length, true)
            if err then
                return { index = work.index, chunk = work.chunk, contextual_info = nil, error = "LLM_ERROR: " .. tostring(err), worker_id = worker_id }
            end
            return { index = work.index, chunk = work.chunk, contextual_info = contextual_info, error = nil, worker_id = worker_id }
        end)

        if success then
            result_ch:send(result_or_err)
        else
            local panic_error = tostring(result_or_err)
            print(string.format("!!! WORKER %d PANIC on chunk %d: %s", worker_id, work.index, panic_error))
            result_ch:send({ index = work.index, chunk = work.chunk, contextual_info = nil, error = "WORKER_PANIC: " .. panic_error, worker_id = worker_id })
        end
    end

    done_ch:send(true)
end

local function process_chunks_parallel(pre_summary, chunks, chunk_enrichment_model, context_length, ops, document_id, max_workers)
    local chunk_count = #chunks
    if chunk_count == 0 then
        return ops, nil
    end

    local first_chunk = chunks[1]
    local warmup_contextual_info, warmup_err
    for retry = 1, CACHE_WARMUP_RETRIES do
        warmup_contextual_info, warmup_err = generate_chunk_context(pre_summary, first_chunk, chunk_enrichment_model, context_length, true)
        if not warmup_err then break end
    end
    if warmup_err then return nil, "Cache warmup failed: " .. warmup_err end

    local enriched_content = #warmup_contextual_info > 0 and (warmup_contextual_info .. "\n\n" .. first_chunk) or first_chunk
    table.insert(ops, { type = "CREATE_NODE", payload = { id = uuid.v7(), parent_id = document_id, node_type = "chunk", content = first_chunk, content_type = "text/plain", embed = enriched_content, metadata = { chunk_index = 1, contextual_prefix = warmup_contextual_info } } })

    if chunk_count == 1 then
        return ops, nil
    end

    local work_items = chunk_count - 1
    local worker_count = calculate_worker_pool_size(work_items, max_workers)

    local work_ch = channel.new(work_items)
    local result_ch = channel.new(work_items)
    local done_ch = channel.new(worker_count)

    for worker_id = 1, worker_count do
        coroutine.spawn(function()
            chunk_worker(worker_id, work_ch, result_ch, done_ch, pre_summary, chunk_enrichment_model, context_length)
        end)
    end

    for i = 2, chunk_count do
        work_ch:send({ index = i, chunk = chunks[i] })
    end
    work_ch:close()

    local results = {}
    local first_error = nil

    for i = 1, work_items do
        local result, ok = result_ch:receive()
        if not ok then
            first_error = "FATAL: Result channel was closed before all results were received."
            break
        end
        if result.error and not first_error then
            first_error = string.format("ERROR from worker for chunk %d: %s", result.index, result.error)
        end
        results[result.index] = result
    end

    -- Wait for all workers to confirm they have finished their loops.
    for i = 1, worker_count do
        done_ch:receive()
    end

    if first_error then
        return nil, first_error
    end

    for i = 2, chunk_count do
        local result = results[i]
        if not result then
            return nil, string.format("Missing result for chunk %d", i)
        end
        local enriched_content = #result.contextual_info > 0 and (result.contextual_info .. "\n\n" .. result.chunk) or result.chunk
        table.insert(ops, { type = "CREATE_NODE", payload = { id = uuid.v7(), parent_id = document_id, node_type = "chunk", content = result.chunk, content_type = "text/plain", embed = enriched_content, metadata = { chunk_index = i, contextual_prefix = result.contextual_info } } })
    end

    return ops, nil
end

---------------------------
-- MAIN HANDLER FUNCTION
---------------------------

local function handle(request)
    local content = request.content or ""
    local content_type = request.content_type or "text/plain"
    local options = request.options or {}
    local original_metadata = request.metadata or {}

    if content == "" then
        return { success = false, error = { code = "MISSING_CONTENT", message = "Content is required" } }
    end

    local chunk_enrichment_model = options.chunk_enrichment_model
    local summary_model = options.summary_model
    local chunk_size = options.chunk_size or 1000
    local overlap = options.overlap or 150
    local summary_length = options.summary_length or 750
    local context_length = options.context_length or 250
    local generate_summaries = options.generate_summaries ~= false
    local generate_title = options.generate_title ~= false
    local title_prompt_tip = options.title_prompt_tip or ""
    local include_code_blocks = options.include_code_blocks ~= false
    local max_workers = options.max_workers or DEFAULT_WORKER_POOL_SIZE

    if not chunk_enrichment_model or not summary_model then
        return { success = false, error = { code = "MISSING_MODEL", message = "Model names are required" } }
    end

    local ops = {}
    local document_id = uuid.v7()
    local document_metadata = {}
    for k, v in pairs(original_metadata) do document_metadata[k] = v end
    document_metadata.chunk_count = 0
    document_metadata.embedded = { models = { chunk_enrichment = chunk_enrichment_model, summary = summary_model }, chunk_size = chunk_size, overlap = overlap }

    table.insert(ops, { type = "CREATE_NODE", payload = { id = document_id, node_type = "document", content = content, content_type = content_type, metadata = document_metadata } })

    local pre_summary, pre_summary_err = generate_pre_summary(content, summary_model, #content)
    if pre_summary_err then return { success = false, error = { code = "PRE_SUMMARY_GENERATION_ERROR", message = "Failed to generate pre-summary: " .. pre_summary_err } } end

    if generate_title and not document_metadata.title then
        local title, title_err = generate_document_title(pre_summary, summary_model, title_prompt_tip)
        document_metadata.title = title_err and "Document" or title
        print(string.format("Generated title: %s", document_metadata.title))
    end

    if generate_summaries then
        local summary_result, err = compress.to_size(summary_model, pre_summary, summary_length, { temperature = PRE_SUMMARY_TEMPERATURE, skip_refinement = false })
        if err then return { success = false, error = { code = "SUMMARY_GENERATION_ERROR", message = "Failed to generate final summary: " .. err } } end
        if summary_result then
            table.insert(ops, { type = "CREATE_NODE", payload = { id = uuid.v7(), parent_id = document_id, node_type = "summary", content = summary_result, content_type = "text/plain", embed = summary_result, metadata = { target_length = summary_length, generated_by = summary_model } } })
        end
    end

    local splitter, err
    if (content_type == "text/markdown" or content_type == "text/html") then
        splitter, err = text.splitter.markdown({ chunk_size = chunk_size, chunk_overlap = overlap, code_blocks = include_code_blocks })
    else
        splitter, err = text.splitter.recursive({ chunk_size = chunk_size, chunk_overlap = overlap })
    end
    if err then return { success = false, error = { code = "SPLITTER_ERROR", message = "Failed to create text splitter: " .. err } } end

    local raw_chunks, err = splitter:split_text(content)
    if err then return { success = false, error = { code = "CHUNKING_ERROR", message = "Failed to split content: " .. err } } end
    if #raw_chunks == 0 then return { success = false, error = { code = "NO_CHUNKS", message = "No chunks generated from content" } } end

    local processed_chunks = merge_small_chunks(raw_chunks, options)
    document_metadata.chunk_count = #processed_chunks
    ops[1].payload.metadata = document_metadata

    local final_ops, process_err = process_chunks_parallel(pre_summary, processed_chunks, chunk_enrichment_model, context_length, ops, document_id, max_workers)
    if process_err then
        return { success = false, error = { code = "CHUNK_PROCESSING_ERROR", message = process_err } }
    end

    return { success = true, ops = final_ops }
end

return { handle = handle }
