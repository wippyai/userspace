local json = require("json")

-- Default prompt templates defined as constants
local DEFAULT_SCOUT_PROMPT = [[
You are an expert document analyzer that helps extract structured information from legal and business documents.
Your task is to analyze the provided document chunks and determine:
1. The confidence level (0-100) for extracting ALL required fields based on available information
2. Which chunks are completely irrelevant and can be safely excluded
3. What additional semantic search queries could help find more relevant information for low-confidence fields
{{notes_section}}
Be conservative with excluding chunks - only mark chunks as irrelevant if they provide NO value to ANY fields.

{{custom_instructions}}

{{fields}}

{{notes}}

{{chunks}}

# Required Analysis

Please analyze the document chunks and provide structured feedback to help extract the fields.
Your response must follow the specified schema format.

Provide:
1. An overall confidence score (0-100) for ALL fields based on current chunk data
2. List of chunk IDs that can be safely excluded
3. Additional semantic search queries that could help find more relevant information for low-confidence fields (provide up to {{max_additional_queries}} queries){{notes_prompt}}
]]

local DEFAULT_EXTRACTION_PROMPT = [[
You are an expert document analyzer that extracts structured information from legal and business documents.
Your task is to analyze the provided document chunks and extract the requested fields with high accuracy.
Base your extraction on the document chunks provided, respecting the field types and validation requirements.

{{custom_instructions}}

{{fields}}

{{analyzer_context}}

{{notes}}

{{chunks}}

Extract the requested field values and provide them in the exact structured format specified by the schema.
]]

local DEFAULT_FIELD_PROMPT = [[
Extract the value for the following field:

Field: {{field_name}}
Type: {{field_type}}
Description: {{field_description}}
Validation hints: {{field_validation}}
Expected output: {{field_expected}}

{{custom_instructions}}

{{chunks}}

Provide ONLY the extracted value without any explanation.
]]

-- Default validation schemas - export these for use in extractor.lua
local DEFAULT_VALIDATION_SCHEMA_NO_NOTES = {
    type = "object",
    properties = {
        overall_confidence = {
            type = "number",
            description = "Overall confidence score (0-100) for extracting ALL fields based on current chunks"
        },
        excluded_chunks = {
            type = "array",
            description = "IDs of chunks that can be safely excluded",
            items = {
                type = "string",
                description = "Chunk ID to exclude"
            }
        },
        additional_queries = {
            type = "array",
            description = "Additional semantic search queries that could help find more relevant information",
            items = {
                type = "object",
                properties = {
                    query = {
                        type = "string",
                        description = "RAG-style similarity search query text"
                    }
                },
                required = { "query" },
                additionalProperties = false
            }
        }
    },
    required = { "overall_confidence", "excluded_chunks", "additional_queries" },
    additionalProperties = false
}

-- Default validation schema with simplified notes (just strings, no type)
local DEFAULT_VALIDATION_SCHEMA_WITH_NOTES = {
    type = "object",
    properties = {
        overall_confidence = {
            type = "number",
            description = "Overall confidence score (0-100) for extracting ALL fields based on current chunks"
        },
        excluded_chunks = {
            type = "array",
            description = "IDs of chunks that can be safely excluded",
            items = {
                type = "string",
                description = "Chunk ID to exclude"
            }
        },
        additional_queries = {
            type = "array",
            description = "Additional semantic search queries that could help find more relevant information",
            items = {
                type = "object",
                properties = {
                    query = {
                        type = "string",
                        description = "RAG-style similarity search query text"
                    }
                },
                required = { "query" },
                additionalProperties = false
            }
        },
        notes = {
            type = "array",
            description = "Observations or notes about the document and extraction process",
            items = {
                type = "string",
                description = "Note content"
            }
        }
    },
    required = { "overall_confidence", "excluded_chunks", "additional_queries", "notes" },
    additionalProperties = false
}

local prompter = {}
prompter.__index = prompter

-- Helper function for template rendering
local function render_template(template, variables)
    if not template or type(template) ~= "string" then
        return ""
    end

    local result = template

    -- Replace {{variable}} with the corresponding value
    result = result:gsub("{{%s*([%w_]+)%s*}}", function(var_name)
        if variables and variables[var_name] ~= nil then
            local var_value = variables[var_name]
            if type(var_value) == "table" then
                return json.encode(var_value)
            else
                return tostring(var_value)
            end
        end
        return ""
    end)

    return result
end

-- Create a new prompter instance
function prompter.new()
    local self = {}
    return setmetatable(self, prompter)
end

-- Format fields from state for prompt inclusion
local function format_fields(entry_config, exclude_direct_analysis)
    if not entry_config or not entry_config.fields then
        return ""
    end

    local result = "# Extraction Fields\n\n"

    for field_name, field_config in pairs(entry_config.fields) do
        -- Skip fields with direct_analysis strategy if requested
        if exclude_direct_analysis and field_config.strategy == "direct_analysis" then
            goto continue
        end

        result = result .. "## " .. field_name .. "\n"
        result = result .. "Type: " .. (field_config.type or "string") .. "\n"

        if field_config.description then
            result = result .. "Description: " .. field_config.description .. "\n"
        end

        if field_config.search_query then
            result = result .. "Sample query: \"" .. field_config.search_query .. "\"\n"
        end

        if field_config.validation_hints then
            result = result .. "Validation hints: " .. field_config.validation_hints .. "\n"
        end

        if field_config.expected_output then
            result = result .. "Expected output: " .. tostring(field_config.expected_output) .. "\n"
        end

        if field_config.type == "enum" and field_config.enum_values then
            local enum_values_str = ""
            if type(field_config.enum_values) == "table" then
                enum_values_str = table.concat(field_config.enum_values, ", ")
            else
                enum_values_str = tostring(field_config.enum_values)
            end
            result = result .. "Allowed values: " .. enum_values_str .. "\n"
        end

        if field_config.type == "array" and field_config.enum_values then
            local enum_values_str = ""
            if type(field_config.enum_values) == "table" then
                enum_values_str = table.concat(field_config.enum_values, ", ")
            else
                enum_values_str = tostring(field_config.enum_values)
            end
            result = result .. "Valid array items: " .. enum_values_str .. "\n"
        end

        result = result .. "\n"

        ::continue::
    end

    return result
end

-- Format analyzer context for prompt inclusion
local function format_analyzer_context(analyzer_context)
    if not analyzer_context or type(analyzer_context) ~= "table" then
        return ""
    end

    local result = "# Direct Analysis Results\n\n"
    result = result .. "The following fields have been analyzed using specialized direct analysis. "
    result = result .. "Use these analysis results as context when extracting the corresponding field values:\n\n"

    for field_name, analysis_text in pairs(analyzer_context) do
        if analysis_text and type(analysis_text) == "string" and string.len(analysis_text) > 0 then
            result = result .. "## " .. field_name .. " Analysis\n\n"
            result = result .. analysis_text .. "\n\n"
        end
    end

    return result
end

-- Format notes for prompt inclusion
local function format_notes(notes, title, include_details)
    if not notes or #notes == 0 then
        return ""
    end

    local result = "# " .. (title or "Previous Observations") .. "\n\n"

    for _, note in ipairs(notes) do
        if include_details then
            result = result .. "## Step " .. note.step .. " - " .. note.type
            if note.field_name then
                result = result .. " (" .. note.field_name .. ")"
            end
            result = result .. "\n" .. note.content .. "\n\n"
        else
            -- Simplified format - just the content
            result = result .. "- " .. note.content .. "\n"
        end
    end

    return result
end

-- Format chunks for prompt inclusion
local function format_chunks(state, max_chunks_per_field)
    max_chunks_per_field = max_chunks_per_field or 5

    local result = "# Document Chunks\n\n"
    local included_chunks = {}

    -- Field-specific chunks
    result = result .. "## Field-Specific Chunks\n\n"

    for _, query in ipairs(state.queries) do
        if query.type == "field" or query.type == "additional" then
            result = result .. "### Query: " .. query.text .. "\n"
            if query.field_name then
                result = result .. "Field: " .. query.field_name .. "\n\n"
            end

            -- Add chunks for this query
            local count = 0
            for _, chunk in ipairs(query.chunks or {}) do
                if chunk and chunk.id and not state:is_chunk_ignored(chunk.id) and not included_chunks[chunk.id] and count < max_chunks_per_field then
                    result = result .. "Chunk ID: " .. chunk.id .. "\n```\n" .. chunk.content .. "\n```\n\n"
                    included_chunks[chunk.id] = true
                    count = count + 1
                end
            end
        end
    end

    -- General context chunks
    result = result .. "## General Context Chunks\n\n"

    for _, query in ipairs(state.queries) do
        if query.type == "prefetch" then
            result = result .. "### Query: " .. query.text .. "\n\n"

            -- Add chunks not already included
            local count = 0
            for _, chunk in ipairs(query.chunks or {}) do
                if chunk and chunk.id and not state:is_chunk_ignored(chunk.id) and not included_chunks[chunk.id] and count < max_chunks_per_field then
                    result = result .. "Chunk ID: " .. chunk.id .. "\n```\n" .. chunk.content .. "\n```\n\n"
                    included_chunks[chunk.id] = true
                    count = count + 1
                end
            end
        end
    end

    return result
end

-- Generate scout/validation prompt
function prompter:generate_scout_prompt(state, options)
    if not state or not state.entry_config then
        return nil, "Invalid state or missing entry configuration"
    end

    options = options or {}
    local include_notes = options.include_notes

    -- Get the scouting configuration
    local scout_config = state.entry_config.scouting or {}

    -- Get max additional queries from config or use default
    local max_additional_queries = scout_config.max_additional_queries or 3

    -- Determine if we include notes in the prompt
    local notes_section = ""
    local notes_prompt = ""
    local notes_content = ""

    if include_notes then
        notes_section =
        "4. Provide observations or notes about the extraction process, challenges, or insights about the document"
        notes_prompt = "\n4. Observations or notes about the document, extraction process, or specific fields"
        notes_content = format_notes(state.notes, "Previous Observations", false)
    end

    -- Create variables for template rendering
    local variables = {
        entry_name = state.entry_name or "document",
        fields = format_fields(state.entry_config, true), -- Exclude direct analysis fields for scouting
        notes = notes_content,
        chunks = format_chunks(state),
        max_additional_queries = max_additional_queries,
        custom_instructions = "",
        notes_section = notes_section,
        notes_prompt = notes_prompt
    }

    -- Include additional custom variables from the entry configuration
    if scout_config.variables then
        for var_name, var_value in pairs(scout_config.variables) do
            variables[var_name] = var_value
        end
    end

    -- Add custom instructions if provided
    if scout_config.prompt and type(scout_config.prompt) == "string" and scout_config.prompt ~= "" then
        variables.custom_instructions = "# Custom Instructions\n\n" .. scout_config.prompt .. "\n"
    end

    -- Render the final template with variables
    local final_prompt = render_template(DEFAULT_SCOUT_PROMPT, variables)

    -- Use appropriate validation schema based on include_notes setting
    local validation_schema
    if include_notes then
        validation_schema = DEFAULT_VALIDATION_SCHEMA_WITH_NOTES
    else
        validation_schema = DEFAULT_VALIDATION_SCHEMA_NO_NOTES
    end

    -- Override with config schema if provided
    if scout_config.schema then
        validation_schema = scout_config.schema
    end

    return final_prompt, validation_schema
end

-- Generate extraction prompt
function prompter:generate_extraction_prompt(state, options)
    if not state or not state.entry_config then
        return nil, "Invalid state or missing entry configuration"
    end

    options = options or {}
    local include_notes = options.include_notes
    local analyzer_context = options.analyzer_context

    -- Get the extraction configuration
    local extraction_config = state.entry_config.extracting or {}

    -- Create variables for template rendering
    local variables = {
        entry_name = state.entry_name or "document",
        fields = format_fields(state.entry_config, false), -- ✅ INCLUDE ALL FIELDS - NEVER EXCLUDE DIRECT ANALYSIS
        notes = include_notes and format_notes(state.notes, "Important Observations About This Document", false) or "",
        chunks = format_chunks(state),
        analyzer_context = format_analyzer_context(analyzer_context),
        custom_instructions = ""
    }

    -- Include additional custom variables from the entry configuration
    if extraction_config.variables then
        for var_name, var_value in pairs(extraction_config.variables) do
            variables[var_name] = var_value
        end
    end

    -- Add custom instructions if provided
    if extraction_config.prompt and type(extraction_config.prompt) == "string" and extraction_config.prompt ~= "" then
        variables.custom_instructions = "# Custom Instructions\n\n" .. extraction_config.prompt .. "\n"
    end

    -- Render the final template with variables
    local final_prompt = render_template(DEFAULT_EXTRACTION_PROMPT, variables)

    return final_prompt
end

-- Generate field-specific prompt
function prompter:generate_field_prompt(state, field_name)
    if not state or not state.entry_config or not field_name then
        return nil, "Invalid state or missing field name"
    end

    local field_config = state.entry_config.fields[field_name]
    if not field_config then
        return nil, "Field not found in configuration"
    end

    -- Get chunks specific to this field
    local field_chunks = state:get_field_chunks(field_name)

    -- Format chunks for prompt
    local chunks_text = "# Field Chunks\n\n"
    for i, chunk in ipairs(field_chunks) do
        chunks_text = chunks_text .. "Chunk " .. i .. ":\n```\n" .. chunk.content .. "\n```\n\n"
    end

    -- Create template variables
    local variables = {
        field_name = field_name,
        field_type = field_config.type or "string",
        field_description = field_config.description or "",
        field_validation = field_config.validation_hints or "",
        field_expected = field_config.expected_output or "",
        chunks = chunks_text,
        custom_instructions = ""
    }

    -- Add any custom field prompt if specified
    if field_config.prompt and type(field_config.prompt) == "string" and field_config.prompt ~= "" then
        variables.custom_instructions = "# Field-Specific Instructions\n\n" .. field_config.prompt .. "\n"
    end

    -- Render the template
    return render_template(DEFAULT_FIELD_PROMPT, variables)
end

-- Export validation schemas
prompter.DEFAULT_VALIDATION_SCHEMA_NO_NOTES = DEFAULT_VALIDATION_SCHEMA_NO_NOTES
prompter.DEFAULT_VALIDATION_SCHEMA_WITH_NOTES = DEFAULT_VALIDATION_SCHEMA_WITH_NOTES

return prompter