local llm = require("llm")
local prompt = require("prompt")
local embeddings = require("embeddings")

local MODELS = {
    QUERY_GENERATION = "gpt-4.1",
    ANALYSIS = "o4-mini"
}

local TEMPERATURE = {
    QUERY_GENERATION = 0.2,
    ANALYSIS = 0.2
}

local MAX_CHUNKS = 100
local DEFAULT_MIN_SIMILARITY = 0.2
local CHUNKS_PER_QUERY = 50
local DEFAULT_CHUNK_LIMIT = 50
local MAX_QUERIES = 5

local QUERY_GENERATION_PROMPT = [[
Main query: {{MAIN_QUERY}}

Analyze the document to answer the query: "{{MAIN_QUERY}}".

Generate up to 5 search queries specifically optimized for RAG (Retrieval-Augmented Generation) to retrieve the most relevant information.

Guidelines for effective RAG queries:
1. Break down the main query into specific aspects (e.g., parties, terms, dates, obligations)
2. Create entity-focused queries targeting names, organizations, and key terms
3. Include queries that use different phrasing than the original query
4. Keep queries simple and focused on key information points
5. Use terminology likely to appear in legal/business documents
6. Avoid complex syntax that wouldn't match natural document language

These queries will be used with vector embeddings to retrieve document chunks, so optimize for semantic similarity.
]]

local ANALYSIS_SYSTEM_PROMPT = [[
You are a Document Analysis Assistant specializing in legal and business document analysis.
Your task is to analyze document content and provide findings that will be used as context for structured data extraction.

IMPORTANT: Your analysis will be provided as context to another AI system that will extract structured data.
Format your analysis to be clear and compatible with structured extraction requirements.

{{FIELD_EXTRACTION_INSTRUCTIONS}}

Guidelines:
1. Base your analysis ONLY on the provided document chunks
2. If the documents don't contain relevant information to answer the query, clearly state this
3. Include page number references when available, formatted as [Page X]
4. Be precise and use terminology that matches the extraction requirements
5. Use clear, direct language that legal and business professionals will understand
6. DO NOT fabricate information not present in the documents
7. Structure your analysis to directly support the extraction goal

Your analysis will be displayed to extraction AI without additional formatting.
]]

local QUERY_SCHEMA = {
    type = "object",
    properties = {
        queries = {
            type = "array",
            items = {
                type = "string"
            },
            description = "An array of search queries related to the main query"
        }
    },
    required = { "queries" },
    additionalProperties = false
}

-- Generate field-aware extraction instructions
local function generate_field_extraction_instructions(field_config)
    if not field_config then
        return "Provide clear, accurate analysis based on the document content."
    end

    local field_type = field_config.type or "string"
    local instructions = "EXTRACTION TARGET:\n"

    -- Field type and description
    instructions = instructions .. "Field Type: " .. field_type
    if field_config.description then
        instructions = instructions .. "\nField Purpose: " .. field_config.description
    end

    -- Type-specific instructions
    if field_type == "array" then
        instructions = instructions .. "\nTarget: Extract multiple items as an array"

        if field_config.enum_values and type(field_config.enum_values) == "table" and #field_config.enum_values > 0 then
            instructions = instructions .. "\nValid Items: "
            local enum_list = table.concat(field_config.enum_values, ", ")
            instructions = instructions .. enum_list
            instructions = instructions .. "\n\nIMPORTANT: When you identify relevant items, reference them using the EXACT names from the valid items list above."
        end

        instructions = instructions .. "\nFormat: Clearly identify each relevant item. If multiple items apply, list them clearly."

    elseif field_type == "string" then
        if field_config.enum_values and type(field_config.enum_values) == "table" and #field_config.enum_values > 0 then
            instructions = instructions .. "\nValid Values: "
            local enum_list = table.concat(field_config.enum_values, ", ")
            instructions = instructions .. enum_list
            instructions = instructions .. "\n\nIMPORTANT: Use the EXACT value name from the valid values list above."
        else
            instructions = instructions .. "\nFormat: Provide clear, concise text that directly answers the query."
        end

    elseif field_type == "number" then
        instructions = instructions .. "\nTarget: Extract a numeric value"
        instructions = instructions .. "\nFormat: Clearly state the number or amount found in the document."

    elseif field_type == "boolean" then
        instructions = instructions .. "\nTarget: Determine true/false or yes/no"
        instructions = instructions .. "\nFormat: Clearly state whether the condition is met (yes/true) or not (no/false)."

    else
        instructions = instructions .. "\nFormat: Provide clear, accurate information based on the document content."
    end

    -- Additional guidance
    if field_config.validation_hints then
        instructions = instructions .. "\n\nValidation Guidance: " .. field_config.validation_hints
    end

    if field_config.expected_output then
        instructions = instructions .. "\nExpected Output Example: " .. tostring(field_config.expected_output)
    end

    return instructions
end

local function analyze_document_chunks(doc_id, query, chunks_count, options)
    options = options or {}
    chunks_count = chunks_count or DEFAULT_CHUNK_LIMIT

    if not doc_id or not query then
        return {
            result = nil,
            tokens = {
                prompt_tokens = 0,
                completion_tokens = 0,
                total_tokens = 0,
                thinking_tokens = 0
            }
        }, "doc_id and query are required"
    end

    local field_config = options.field_config
    if field_config and field_config.chunks then
        chunks_count = field_config.chunks
    end

    chunks_count = math.min(chunks_count, MAX_CHUNKS)

    local total_tokens = {
        prompt_tokens = 0,
        completion_tokens = 0,
        total_tokens = 0,
        thinking_tokens = 0
    }

    local query_prompt = QUERY_GENERATION_PROMPT:gsub("{{MAIN_QUERY}}", query)

    local query_response, err = llm.structured_output(
        QUERY_SCHEMA,
        query_prompt,
        {
            model = MODELS.QUERY_GENERATION,
            options = {
                temperature = TEMPERATURE.QUERY_GENERATION
            }
        }
    )

    if err then
        return {
            result = nil,
            tokens = total_tokens
        }, "Failed to generate search queries: " .. err
    end

    if query_response and query_response.tokens then
        total_tokens.prompt_tokens = total_tokens.prompt_tokens + (query_response.tokens.prompt_tokens or 0)
        total_tokens.completion_tokens = total_tokens.completion_tokens + (query_response.tokens.completion_tokens or 0)
        total_tokens.total_tokens = total_tokens.total_tokens + (query_response.tokens.total_tokens or 0)
        if query_response.tokens.thinking_tokens then
            total_tokens.thinking_tokens = total_tokens.thinking_tokens + query_response.tokens.thinking_tokens
        end
    end

    local queries = {}
    local original_query = query

    table.insert(queries, original_query)

    if query_response and query_response.result and query_response.result.queries then
        for i = 1, math.min(#query_response.result.queries, MAX_QUERIES - 1) do
            local generated_query = query_response.result.queries[i]
            if generated_query ~= original_query then
                table.insert(queries, generated_query)
            end
        end
    end

    local all_chunks = {}
    local chunk_seen = {}
    local total_chunks_found = 0

    for i, search_query in ipairs(queries) do
        local query_search_options = {
            limit = CHUNKS_PER_QUERY,
            origin_id = doc_id
        }

        local results, search_err = embeddings.search(search_query, query_search_options)

        if results then
            for _, result in ipairs(results) do
                local normalized_similarity = (result.similarity + 1) / 2

                if normalized_similarity >= DEFAULT_MIN_SIMILARITY then
                    if not chunk_seen[result.entry_id] then
                        chunk_seen[result.entry_id] = true
                        total_chunks_found = total_chunks_found + 1

                        local chunk_info = {
                            content = result.content,
                            similarity = normalized_similarity,
                            meta = result.meta or {},
                            query = search_query
                        }

                        table.insert(all_chunks, chunk_info)
                    end
                end
            end
        end
    end

    if #all_chunks == 0 then
        return {
            result = nil,
            tokens = total_tokens
        }, "No relevant document content found for the queries"
    end

    table.sort(all_chunks, function(a, b) return a.similarity > b.similarity end)

    if #all_chunks > chunks_count then
        all_chunks = { unpack(all_chunks, 1, chunks_count) }
    end

    -- Generate field-aware extraction instructions
    local field_extraction_instructions = generate_field_extraction_instructions(field_config)

    -- Create analysis system prompt with field instructions
    local analysis_system_prompt = ANALYSIS_SYSTEM_PROMPT:gsub("{{FIELD_EXTRACTION_INSTRUCTIONS}}", field_extraction_instructions)

    local analysis_builder = prompt.new()

    analysis_builder:add_system(analysis_system_prompt)
    analysis_builder:add_system("\nOriginal Query: " .. query)

    if doc_id then
        analysis_builder:add_system("\nDocument ID: " .. doc_id)
    end

    analysis_builder:add_user(query)

    local context = "I'll analyze this query based on the following document chunks:\n\n"

    for i, chunk in ipairs(all_chunks) do
        context = context .. "--- Chunk " .. i .. " (Query: \"" .. chunk.query .. "\") ---\n"

        if chunk.meta then
            if chunk.meta.filename then
                context = context .. "Source: " .. chunk.meta.filename .. "\n"
            end
            if chunk.meta.page_num then
                context = context .. "Page: " .. chunk.meta.page_num .. "\n"
            end
            if chunk.meta.chunk_index then
                context = context .. "Chunk Index: " .. chunk.meta.chunk_index .. "\n"
            end
        end

        context = context .. "Content: " .. chunk.content .. "\n\n"
    end

    analysis_builder:add_assistant(context)

    local analysis_response, err = llm.generate(
        analysis_builder,
        {
            model = MODELS.ANALYSIS,
            options = {
                temperature = TEMPERATURE.ANALYSIS,
                max_tokens = 2000
            }
        }
    )

    if err then
        return {
            result = nil,
            tokens = total_tokens
        }, "Failed to analyze document: " .. err
    end

    if analysis_response and analysis_response.tokens then
        total_tokens.prompt_tokens = total_tokens.prompt_tokens + (analysis_response.tokens.prompt_tokens or 0)
        total_tokens.completion_tokens = total_tokens.completion_tokens + (analysis_response.tokens.completion_tokens or 0)
        total_tokens.total_tokens = total_tokens.total_tokens + (analysis_response.tokens.total_tokens or 0)
        if analysis_response.tokens.thinking_tokens then
            total_tokens.thinking_tokens = total_tokens.thinking_tokens + analysis_response.tokens.thinking_tokens
        end
    end

    return {
        result = analysis_response.result,
        tokens = total_tokens
    }, nil
end

return {
    analyze_document_chunks = analyze_document_chunks
}
