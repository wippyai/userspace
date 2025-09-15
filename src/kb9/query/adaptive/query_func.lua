local ctx = require("ctx")
local reader = require("reader")
local llm = require("llm")
local json = require("json")

-- Constants
local VECTOR_DIMENSIONS = 512
local DEFAULT_LIMIT = 10
local DEFAULT_SUMMARY_MULTIPLIER = 3
local MAX_SUMMARIES = 20
local CONTENT_PREVIEW_LENGTH = 800
local RANKING_PREVIEW_LENGTH = 400
local MIN_CHUNKS_PER_DOC = 1

-- Node Types
local NODE_TYPES = {
    SUMMARY = "summary",
    CHUNK = "chunk"
}

-- Error Codes
local ERRORS = {
    MISSING_CONTEXT = "MISSING_CONTEXT",
    INVALID_INPUT_VECTOR = "INVALID_INPUT_VECTOR",
    MISSING_PARAMETER = "MISSING_PARAMETER",
    MISSING_MODEL = "MISSING_MODEL",
    SUMMARY_SEARCH_FAILED = "SUMMARY_SEARCH_FAILED",
    EMBEDDING_FAILED = "EMBEDDING_FAILED"
}

-- LLM Prompts
local DOCUMENT_ANALYSIS_PROMPT = [[CONTEXT: This is a two-stage search system. You are in stage 1 - document filtering.

USER QUERY: "%s"

DOCUMENT SUMMARIES:
%s

YOUR JOB:
1. These are high-level document summaries, NOT the full content
2. After this step, we will search for specific chunks/sections within relevant documents
3. The detailed implementation content is in the chunks, not these summaries
4. Mark "relevant" = true if this document COULD contain information that helps answer the query
5. If relevant=true, create a targeted search query to find the right chunks within that document

DECISION CRITERIA:
- Be INCLUSIVE - if there's any reasonable chance this document contains helpful information, mark it relevant
- Remember: the specific details you need are likely in the document chunks, not this high-level summary
- Focus on topic/domain match, not whether the summary directly answers the question

%sFor each document, decide relevance and create search strategy:]]

local RERANKING_PROMPT = [[Original user query: "%s"

Search results to rank:
%s

Rank these results by relevance to the user's query (0-100 score):]]

-- LLM Schemas
local DOCUMENT_ANALYSIS_SCHEMA = {
    type = "object",
    properties = {
        documents = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    document_id = { type = "string" },
                    relevant = { type = "boolean" },
                    search_query = { type = "string" },
                    reasoning = { type = "string" }
                },
                required = { "document_id", "relevant", "search_query", "reasoning" },
                additionalProperties = false
            }
        }
    },
    required = { "documents" },
    additionalProperties = false
}

local RERANKING_SCHEMA = {
    type = "object",
    properties = {
        rankings = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    result_id = { type = "string" },
                    score = { type = "number", minimum = 0, maximum = 100 }
                },
                required = { "result_id", "score" },
                additionalProperties = false
            }
        }
    },
    required = { "rankings" },
    additionalProperties = false
}

local function generate_document_strategies(user_query, summary_results, analysis_model, extra_prompt)
    if #summary_results == 0 then
        return {}, nil
    end

    -- Handle nil content properly without filtering
    local documents = {}
    for _, summary in ipairs(summary_results) do
        local document_id = summary.parent_id or summary.id
        local content = summary.content or ""
        table.insert(documents, {
            document_id = document_id,
            summary = content:sub(1, math.min(#content, CONTENT_PREVIEW_LENGTH))
        })
    end

    local extra_instructions = ""
    if extra_prompt and extra_prompt ~= "" then
        extra_instructions = "\n\nAdditional instructions:\n" .. extra_prompt .. "\n\n"
    end

    local prompt = string.format(DOCUMENT_ANALYSIS_PROMPT, user_query, json.encode(documents), extra_instructions)

    local response, err = llm.structured_output(DOCUMENT_ANALYSIS_SCHEMA, prompt, {
        model = analysis_model,
        temperature = 0.3
    })

    if err then
        return nil, err
    end

    local strategies = {}
    if response.result and response.result.documents then
        for _, item in ipairs(response.result.documents) do
            if item.relevant and item.search_query and item.search_query ~= "" then
                strategies[item.document_id] = {
                    search_query = item.search_query,
                    reasoning = item.reasoning
                }
            end
        end
    end

    return strategies, nil
end

local function embed_search_queries(queries, embedding_model)
    if #queries == 0 then
        return {}, nil
    end

    local response, err = llm.embed(queries, {
        model = embedding_model,
        dimensions = VECTOR_DIMENSIONS
    })

    if err then
        return nil, err
    end

    if not response.result or #response.result ~= #queries then
        return nil, "Embedding batch size mismatch"
    end

    return response.result, nil
end

local function search_chunks_in_document(kb_reader, doc_id, doc_path, query_embedding, chunks_per_doc)
    -- Try path-based search first (more precise)
    if doc_path then
        local chunk_results, err = kb_reader
            :under(doc_path)
            :near_vector(query_embedding)
            :limit(chunks_per_doc)
            :of_type(NODE_TYPES.CHUNK)
            :include_content()
            :include_metadata()
            :all()

        if chunk_results and #chunk_results > 0 then
            return chunk_results, nil
        end
    end

    -- Fallback to children-based search
    return kb_reader
        :children_of(doc_id)
        :near_vector(query_embedding)
        :limit(chunks_per_doc)
        :of_type(NODE_TYPES.CHUNK)
        :include_content()
        :include_metadata()
        :all()
end

local function rerank_results(user_query, all_results, analysis_model)
    if #all_results == 0 then
        return all_results, nil
    end

    local results_for_ranking = {}
    for _, result in ipairs(all_results) do
        local content = result.content or ""
        table.insert(results_for_ranking, {
            result_id = result.id,
            content = content:sub(1, math.min(#content, RANKING_PREVIEW_LENGTH)),
            node_type = result.node_type,
            similarity = result.similarity
        })
    end

    local prompt = string.format(RERANKING_PROMPT, user_query, json.encode(results_for_ranking))

    local response, err = llm.structured_output(RERANKING_SCHEMA, prompt, {
        model = analysis_model,
        temperature = 0
    })

    if err then
        return all_results, nil
    end

    if not response.result or not response.result.rankings then
        return all_results, nil
    end

    local id_to_score = {}
    for _, ranking in ipairs(response.result.rankings) do
        id_to_score[ranking.result_id] = ranking.score
    end

    for _, result in ipairs(all_results) do
        result.llm_score = id_to_score[result.id] or 0
    end

    table.sort(all_results, function(a, b)
        if a.llm_score ~= b.llm_score then
            return a.llm_score > b.llm_score
        end
        return a.similarity > b.similarity
    end)

    return all_results, nil
end

local function handle(request)
    local query_text = request.query
    local input_vector = request.input_vector
    local embedding_model = request.embedding_model
    local limit = request.limit or DEFAULT_LIMIT
    local options = request.options or {}

    -- Validate context
    local component_id = ctx.get("component_id")
    if not component_id then
        return {
            success = false,
            error = {
                code = ERRORS.MISSING_CONTEXT,
                message = "component_id not found in context"
            }
        }
    end

    -- Validate input vector
    if not input_vector or type(input_vector) ~= "table" or #input_vector ~= VECTOR_DIMENSIONS then
        return {
            success = false,
            error = {
                code = ERRORS.INVALID_INPUT_VECTOR,
                message = "input_vector must be array of " .. VECTOR_DIMENSIONS .. " numbers"
            }
        }
    end

    -- Validate required models
    if not embedding_model then
        return {
            success = false,
            error = {
                code = ERRORS.MISSING_PARAMETER,
                message = "embedding_model is required"
            }
        }
    end

    local analysis_model = options.analysis_model
    if not analysis_model then
        return {
            success = false,
            error = {
                code = ERRORS.MISSING_MODEL,
                message = "analysis_model is required in options"
            }
        }
    end

    local extra_prompt = options.extra_prompt or ""
    local enable_reranking = options.enable_reranking

    local kb_reader = reader.for_kb(component_id)

    -- Stage 1: Find document summaries using original query
    local summary_limit = math.min(limit * DEFAULT_SUMMARY_MULTIPLIER, MAX_SUMMARIES)
    local summary_results, err = kb_reader
        :near_vector(input_vector)
        :limit(summary_limit)
        :of_type(NODE_TYPES.SUMMARY)
        :include_content()
        :include_metadata()
        :all()

    if not summary_results then
        return {
            success = false,
            error = {
                code = ERRORS.SUMMARY_SEARCH_FAILED,
                message = "Failed to search summaries: " .. (err or "unknown error")
            }
        }
    end

    if #summary_results == 0 then
        return { success = true, items = {}, count = 0 }
    end

    -- Stage 2: AI analyzes summaries and generates targeted search queries
    local strategies, strategy_err = generate_document_strategies(query_text, summary_results, analysis_model, extra_prompt)

    if strategy_err then
        -- Fallback: use original query for all documents
        strategies = {}
        for _, summary in ipairs(summary_results) do
            local document_id = summary.parent_id or summary.id
            strategies[document_id] = {
                search_query = query_text,
                reasoning = "Fallback due to strategy generation failure"
            }
        end
    end

    local relevant_doc_count = 0
    for _ in pairs(strategies) do
        relevant_doc_count = relevant_doc_count + 1
    end

    -- Enhanced fallback: If no documents are relevant, use fallback strategy
    if relevant_doc_count == 0 then
        -- Fallback: treat all summary documents as relevant with original query
        strategies = {}
        for _, summary in ipairs(summary_results) do
            local document_id = summary.parent_id or summary.id
            strategies[document_id] = {
                search_query = query_text,
                reasoning = "Fallback: AI marked as irrelevant but treating as relevant"
            }
        end

        relevant_doc_count = 0
        for _ in pairs(strategies) do
            relevant_doc_count = relevant_doc_count + 1
        end
    end

    -- Stage 3: Batch embed all unique search queries for efficiency
    local unique_queries = {}
    local query_to_docs = {}
    for doc_id, strategy in pairs(strategies) do
        local query = strategy.search_query
        if not query_to_docs[query] then
            query_to_docs[query] = {}
            table.insert(unique_queries, query)
        end
        table.insert(query_to_docs[query], doc_id)
    end

    local query_embeddings, embed_err = embed_search_queries(unique_queries, embedding_model)
    if embed_err then
        return {
            success = false,
            error = {
                code = ERRORS.EMBEDDING_FAILED,
                message = "Failed to embed search queries: " .. embed_err
            }
        }
    end

    -- Stage 4: Search for chunks in relevant documents using reader filters
    local all_chunk_results = {}
    local chunks_per_doc = math.max(MIN_CHUNKS_PER_DOC, math.ceil(limit / relevant_doc_count))

    for i, query in ipairs(unique_queries) do
        local query_embedding = query_embeddings[i]
        local doc_ids = query_to_docs[query]

        for _, doc_id in ipairs(doc_ids) do
            -- Find the summary for this document to get its path
            local doc_path = nil
            for _, summary in ipairs(summary_results) do
                local summary_doc_id = summary.parent_id or summary.id
                if summary_doc_id == doc_id then
                    doc_path = summary.path
                    break
                end
            end

            -- Search chunks using reader filters
            local chunk_results, search_err = search_chunks_in_document(
                kb_reader,
                doc_id,
                doc_path,
                query_embedding,
                chunks_per_doc
            )

            if chunk_results and #chunk_results > 0 then
                for _, chunk in ipairs(chunk_results) do
                    table.insert(all_chunk_results, chunk)
                end
            end
        end
    end

    -- Stage 5: Combine relevant summaries with chunks
    local all_results = {}

    -- Strategy options for summary inclusion
    local summary_strategy = options.summary_strategy or "mixed"

    if summary_strategy == "chunks_only" then
        -- Add no summaries
    elseif summary_strategy == "smart_threshold" then
        -- Calculate average chunk similarity
        local chunk_sim_sum = 0
        for _, chunk in ipairs(all_chunk_results) do
            chunk_sim_sum = chunk_sim_sum + (chunk.similarity or 0)
        end
        local avg_chunk_sim = #all_chunk_results > 0 and (chunk_sim_sum / #all_chunk_results) or 0

        -- Add summaries only if they beat average chunk similarity
        for _, summary in ipairs(summary_results) do
            local doc_id = summary.parent_id or summary.id
            if strategies[doc_id] and (summary.similarity or 0) > avg_chunk_sim then
                table.insert(all_results, summary)
            end
        end
    else
        -- Default "mixed" strategy - Add summaries from relevant documents only
        for _, summary in ipairs(summary_results) do
            local doc_id = summary.parent_id or summary.id
            if strategies[doc_id] then
                table.insert(all_results, summary)
            end
        end
    end

    -- Add all found chunks
    for _, chunk in ipairs(all_chunk_results) do
        table.insert(all_results, chunk)
    end

    if #all_results == 0 then
        return { success = true, items = {}, count = 0 }
    end

    -- Stage 6: Optional reranking with LLM
    local final_results = all_results
    if enable_reranking then
        local reranked_results, rerank_err = rerank_results(query_text, all_results, analysis_model)
        if rerank_err then
            -- Fallback to similarity sorting
            table.sort(final_results, function(a, b) return a.similarity > b.similarity end)
        else
            final_results = reranked_results
        end
    else
        table.sort(final_results, function(a, b) return a.similarity > b.similarity end)
    end

    -- Stage 7: Apply final limit
    if #final_results > limit then
        local limited = {}
        for i = 1, limit do
            table.insert(limited, final_results[i])
        end
        final_results = limited
    end

    return {
        success = true,
        items = final_results,
        count = #final_results
    }
end

return { handle = handle }