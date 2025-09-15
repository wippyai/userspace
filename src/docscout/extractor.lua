local state_module = require("state")
local prompter_module = require("prompter")
local registry = require("config_registry")
local llm = require("llm")
local funcs = require("funcs")
local json = require("json")

local ANALYZER_FUNCTION_ID = "userspace.docscout:analyzer"

local extractor = {}
extractor.__index = extractor

local function log_info(message)
    print("[INFO] " .. message)
end

local function log_error(message)
    print("[ERROR] " .. message)
end

local function log_debug(message)
    print("[DEBUG] " .. message)
end

function extractor.new(file_uuid, entry_id, options)
    if not file_uuid then
        return nil, "Missing required parameter: file_uuid"
    end

    if not entry_id then
        return nil, "Missing required parameter: entry_id"
    end

    options = options or {}

    local entry_config, err = registry.get_entry(entry_id)
    if not entry_config then
        return nil, "Failed to load entry configuration: " .. (err or "unknown error")
    end

    local scouting_config = entry_config.scouting or {}
    local extracting_config = entry_config.extracting or {}
    local options_config = entry_config.options or {}

    local config = {
        scout_model = options.scout_model or scouting_config.model,
        validation_steps = options.validation_steps,
        min_confidence = options.min_confidence,
        max_additional_queries = options.max_additional_queries,

        extraction_model = options.extraction_model or extracting_config.model,
        structured_output = options.structured_output,

        scout_max_tokens = options.scout_max_tokens or scouting_config.max_tokens,
        extraction_max_tokens = options.extraction_max_tokens or extracting_config.max_tokens,

        shared_context = options.shared_context,

        callbacks = options.callbacks or {}
    }

    if config.validation_steps == nil and scouting_config.max_iterations ~= nil then
        config.validation_steps = scouting_config.max_iterations
    end

    if config.min_confidence == nil and scouting_config.min_confidence ~= nil then
        local confidence = scouting_config.min_confidence
        if confidence <= 1 then
            confidence = confidence * 100
        end
        config.min_confidence = confidence
    end

    if config.max_additional_queries == nil and scouting_config.max_additional_queries ~= nil then
        config.max_additional_queries = scouting_config.max_additional_queries
    end

    if config.structured_output == nil and extracting_config.structured_output ~= nil then
        config.structured_output = extracting_config.structured_output
    end

    if config.shared_context == nil and options_config.shared_context ~= nil then
        config.shared_context = options_config.shared_context
    end

    if config.validation_steps == nil then config.validation_steps = 0 end
    if config.min_confidence == nil then config.min_confidence = 70 end
    if config.max_additional_queries == nil then config.max_additional_queries = 3 end
    if config.structured_output == nil then config.structured_output = true end
    if config.shared_context == nil then config.shared_context = true end

    if config.validation_steps > 0 and not config.scout_model then
        return nil, "Scout model must be specified in options or configuration when validation_steps > 0"
    end

    if not config.extraction_model then
        return nil, "Extraction model must be specified in options or configuration"
    end

    log_info("Scout model: " .. (config.scout_model or "NONE - Validation will be skipped"))
    log_info("Extraction model: " .. (config.extraction_model or "NONE - THIS WILL FAIL"))
    log_info("Validation steps: " .. config.validation_steps)
    log_info("Shared context: " .. tostring(config.shared_context))
    if config.scout_max_tokens then
        log_info("Scout max tokens: " .. config.scout_max_tokens)
    end
    if config.extraction_max_tokens then
        log_info("Extraction max tokens: " .. config.extraction_max_tokens)
    end

    local self = {
        file_uuid = file_uuid,
        entry_id = entry_id,
        state = nil,
        prompter = prompter_module.new(),
        options = config,
        analyzer_context = {},
        metrics = {
            validation_tokens = {
                prompt_tokens = 0,
                completion_tokens = 0,
                total_tokens = 0
            },
            extraction_tokens = {
                prompt_tokens = 0,
                completion_tokens = 0,
                total_tokens = 0
            },
            total_tokens = 0,
            validation_steps_performed = 0,
            excluded_chunks = 0,
            additional_queries = 0,
            confidence_by_step = {}
        }
    }

    if self.options.callbacks.on_init then
        self.options.callbacks.on_init({
            file_uuid = file_uuid,
            entry_id = entry_id,
            config = config
        })
    end

    return setmetatable(self, extractor)
end

function extractor:initialize()
    self.state = state_module.new(self.file_uuid, self.entry_id)

    local success, err = self.state:initialize()
    if not success then
        return false, err
    end

    if self.options.callbacks.on_state_init then
        self.options.callbacks.on_state_init({
            state_summary = self.state:get_state_summary()
        })
    end

    return true
end

function extractor:_update_metrics(phase, tokens)
    if not tokens then return end

    if phase == "validation" then
        self.metrics.validation_tokens.prompt_tokens = self.metrics.validation_tokens.prompt_tokens +
            (tokens.prompt_tokens or 0)
        self.metrics.validation_tokens.completion_tokens = self.metrics.validation_tokens.completion_tokens +
            (tokens.completion_tokens or 0)
        self.metrics.validation_tokens.total_tokens = self.metrics.validation_tokens.total_tokens +
            (tokens.total_tokens or 0)

        if tokens.thinking_tokens then
            self.metrics.validation_tokens.thinking_tokens = (self.metrics.validation_tokens.thinking_tokens or 0) +
                tokens.thinking_tokens
        end
    elseif phase == "extraction" then
        self.metrics.extraction_tokens.prompt_tokens = self.metrics.extraction_tokens.prompt_tokens +
            (tokens.prompt_tokens or 0)
        self.metrics.extraction_tokens.completion_tokens = self.metrics.extraction_tokens.completion_tokens +
            (tokens.completion_tokens or 0)
        self.metrics.extraction_tokens.total_tokens = self.metrics.extraction_tokens.total_tokens +
            (tokens.total_tokens or 0)

        if tokens.thinking_tokens then
            self.metrics.extraction_tokens.thinking_tokens = (self.metrics.extraction_tokens.thinking_tokens or 0) +
                tokens.thinking_tokens
        end
    end

    self.metrics.total_tokens = self.metrics.validation_tokens.total_tokens + self.metrics.extraction_tokens.total_tokens

    if (self.metrics.validation_tokens.thinking_tokens or 0) > 0 or (self.metrics.extraction_tokens.thinking_tokens or 0) > 0 then
        self.metrics.thinking_tokens = (self.metrics.validation_tokens.thinking_tokens or 0) +
            (self.metrics.extraction_tokens.thinking_tokens or 0)
    end

    if self.options.callbacks.on_metrics_update then
        self.options.callbacks.on_metrics_update({
            phase = phase,
            metrics = self:get_metrics()
        })
    end
end

function extractor:_process_validation_results(result)
    if result.overall_confidence then
        table.insert(self.metrics.confidence_by_step, result.overall_confidence)
    end

    if self.options.shared_context and result.notes then
        if type(result.notes) == "table" then
            if result.notes[1] and type(result.notes[1]) == "string" then
                for _, note_text in ipairs(result.notes) do
                    if type(note_text) == "string" and string.len(note_text) > 0 then
                        self.state:add_note(note_text, "general", nil)
                    end
                end
            elseif result.notes[1] and type(result.notes[1]) == "table" then
                for _, note_info in ipairs(result.notes) do
                    if type(note_info) == "table" and type(note_info.content) == "string" then
                        local note_type = note_info.type or "general"
                        self.state:add_note(note_info.content, note_type, note_info.field_name)
                    end
                end
            end
        elseif type(result.notes) == "string" then
            self.state:add_note(result.notes, "general", nil)
        end
    end

    if result.excluded_chunks and type(result.excluded_chunks) == "table" and #result.excluded_chunks > 0 then
        local excluded = self.state:exclude_chunk_ids(result.excluded_chunks)
        self.metrics.excluded_chunks = self.metrics.excluded_chunks + excluded
    end

    local queries_added = 0
    if result.additional_queries and type(result.additional_queries) == "table" then
        for _, query_info in ipairs(result.additional_queries) do
            local query_text = nil
            if type(query_info) == "string" then
                query_text = query_info
            elseif type(query_info) == "table" and type(query_info.query) == "string" then
                query_text = query_info.query
            end

            if query_text and string.len(query_text) > 0 then
                if queries_added < self.options.max_additional_queries then
                    local result, err = self.state:run_query(query_text, { type = "additional" })

                    if result then
                        queries_added = queries_added + 1
                    end
                end
            end
        end
    end

    self.metrics.additional_queries = self.metrics.additional_queries + queries_added

    return queries_added > 0
end

function extractor:validate()
    if not self.options.scout_model or self.options.validation_steps <= 0 then
        log_info("Skipping validation: No scout model or validation_steps <= 0")
        return {}, nil
    end

    local step = 0
    local continue_validation = true
    local validation_results = {}
    local validation_prompts = {}
    local validation_responses = {}

    while continue_validation and step < self.options.validation_steps do
        step = step + 1
        self.metrics.validation_steps_performed = step

        local prompt, custom_validation_schema = self.prompter:generate_scout_prompt(self.state, {
            include_notes = self.options.shared_context
        })

        validation_prompts[step] = prompt

        if self.options.callbacks.on_validation_prompt then
            self.options.callbacks.on_validation_prompt({
                step = step,
                prompt = prompt,
                validation_schema = custom_validation_schema
            })
        end

        log_info("Running validation step " .. step .. " with model: " .. self.options.scout_model)

        local validation_schema = custom_validation_schema
        if not validation_schema then
            if self.options.shared_context then
                validation_schema = prompter_module.DEFAULT_VALIDATION_SCHEMA_WITH_NOTES
            else
                validation_schema = prompter_module.DEFAULT_VALIDATION_SCHEMA_NO_NOTES
            end
        end

        local llm_options = {
            model = self.options.scout_model,
            temperature = 0.1
        }

        if self.options.scout_max_tokens then
            llm_options.max_tokens = self.options.scout_max_tokens
        end

        local response, err = llm.structured_output(
            validation_schema,
            prompt,
            llm_options
        )

        if err then
            if self.options.callbacks.on_error then
                self.options.callbacks.on_error({
                    phase = "validation",
                    step = step,
                    error = err
                })
            end
            return nil, "Validation step failed: " .. tostring(err)
        end

        if response.error then
            if self.options.callbacks.on_error then
                self.options.callbacks.on_error({
                    phase = "validation",
                    step = step,
                    error = response.error
                })
            end
            return nil, "Validation step failed: " .. tostring(response.error)
        end

        validation_responses[step] = response.result

        local validation_result = response.result
        if not validation_result then
            return nil, "Validation response is empty or null"
        end

        if type(validation_result.overall_confidence) ~= "number" or
            type(validation_result.excluded_chunks) ~= "table" or
            type(validation_result.additional_queries) ~= "table" then
            return nil, "Validation response structure is invalid or missing required fields."
        end

        if self.options.shared_context and type(validation_result.notes) ~= "table" then
            validation_result.notes = {}
        end

        validation_result._prompt = prompt
        table.insert(validation_results, validation_result)

        self:_update_metrics("validation", response.tokens)

        if self.options.callbacks.on_validation_result then
            self.options.callbacks.on_validation_result({
                step = step,
                result = validation_result,
                tokens = response.tokens,
                prompt = prompt
            })
        end

        local queries_added = self:_process_validation_results(validation_result)

        continue_validation = false
        if validation_result.overall_confidence < self.options.min_confidence and step < self.options.validation_steps then
            if queries_added then
                continue_validation = true
            end
        end
    end

    self.validation_prompts = validation_prompts
    self.validation_responses = validation_responses

    if self.options.callbacks.on_validation_complete then
        self.options.callbacks.on_validation_complete({
            steps_performed = self.metrics.validation_steps_performed,
            results = validation_results,
            prompts = validation_prompts,
            responses = validation_responses,
            metrics = self:get_metrics()
        })
    end

    return validation_results, nil
end

function extractor:_start_parallel_direct_analysis()
    if not self.state or not self.state.entry_config or not self.state.entry_config.fields then
        return {}
    end

    local analysis_commands = {}
    local executor = funcs.new()

    for field_name, field_config in pairs(self.state.entry_config.fields) do
        if field_config.strategy == "direct_analysis" then
            log_info("Starting parallel direct analysis for field: " .. field_name)

            local query = field_config.search_query
            if not query or query == "" then
                query = field_config.description or field_name
            end

            local chunks_count = field_config.chunks or 10

            local command = executor:async(ANALYZER_FUNCTION_ID, self.file_uuid, query, chunks_count, {
                field_config = field_config
            })

            analysis_commands[field_name] = command
        end
    end

    return analysis_commands
end

function extractor:_collect_analysis_results(analysis_commands)
    local direct_analysis_context = {}

    for field_name, command in pairs(analysis_commands) do
        log_info("Collecting analysis result for field: " .. field_name)

        local channel = command:response()
        local payload_wrapper, ok = channel:receive()

        if not ok then
            log_error("Failed to receive analysis result for field: " .. field_name)
            direct_analysis_context[field_name] = "Analysis Error: Failed to receive result"
        else
            local payload, err = command:result()
            if err then
                log_error("Direct analysis failed for field " .. field_name .. ": " .. err)
                direct_analysis_context[field_name] = "Analysis Error: " .. err
            else
                log_info("Direct analysis completed for field: " .. field_name)

                local result = payload:data()

                if type(result) == "table" and result.tokens then
                    self:_update_metrics("extraction", result.tokens)
                    direct_analysis_context[field_name] = result.result or "No analysis result"
                else
                    direct_analysis_context[field_name] = result or "No analysis result"
                end
            end
        end
    end

    return direct_analysis_context
end

function extractor:_build_extraction_schema()
    local schema = {
        type = "object",
        properties = {},
        required = {},
        additionalProperties = false
    }

    if self.state and self.state.entry_config and self.state.entry_config.fields then
        for field_name, field_config in pairs(self.state.entry_config.fields) do
            local property = {
                description = field_config.description or ""
            }

            if field_config.type == "number" then
                property.type = "number"
            elseif field_config.type == "boolean" then
                property.type = "boolean"
            elseif field_config.type == "enum" then
                property.type = "string"
                if field_config.enum_values then
                    property.enum = field_config.enum_values
                end
            elseif field_config.type == "array" then
                property.type = "array"
                property.items = {
                    type = field_config.item_type or "string"
                }

                if field_config.enum_values then
                    property.items.enum = field_config.enum_values
                end
            else
                property.type = "string"
            end

            schema.properties[field_name] = property
            table.insert(schema.required, field_name)
        end
    end

    if not schema.properties or type(schema.properties) ~= "table" or next(schema.properties) == nil then
        log_info("No extraction fields found")
        return nil
    else
        log_info("Schema generated with " .. #schema.required .. " extraction fields")
    end

    return schema
end

function extractor:extract()
    local analysis_commands = self:_start_parallel_direct_analysis()

    local schema = self:_build_extraction_schema()
    if not schema then
        log_info("No fields to extract")
        return {}, nil
    end

    local direct_analysis_context = self:_collect_analysis_results(analysis_commands)

    self.analyzer_context = direct_analysis_context

    local prompt = self.prompter:generate_extraction_prompt(self.state, {
        include_notes = self.options.shared_context,
        analyzer_context = direct_analysis_context
    })

    self.extraction_prompt = prompt

    if self.options.callbacks.on_extraction_prompt then
        self.options.callbacks.on_extraction_prompt({
            prompt = prompt,
            analyzer_context = direct_analysis_context
        })
    end

    log_info("Running extraction with model: " .. self.options.extraction_model)

    local llm_options = {
        model = self.options.extraction_model,
        temperature = 0.2
    }

    if self.options.extraction_max_tokens then
        llm_options.max_tokens = self.options.extraction_max_tokens
    end

    local response, err
    if self.options.structured_output then
        response, err = llm.structured_output(
            schema,
            prompt,
            llm_options
        )
    else
        response, err = llm.generate(
            prompt,
            llm_options
        )
    end

    if err then
        if self.options.callbacks.on_error then
            self.options.callbacks.on_error({
                phase = "extraction",
                error = err
            })
        end
        return nil, "Extraction failed: " .. tostring(err)
    end

    if response.error then
        if self.options.callbacks.on_error then
            self.options.callbacks.on_error({
                phase = "extraction",
                error = response.error
            })
        end
        return nil, "Extraction failed: " .. (response.error_message or response.error)
    end

    if response.result then
        self.extraction_response = response.result
    end

    self:_update_metrics("extraction", response.tokens)

    if self.options.callbacks.on_extraction_result then
        self.options.callbacks.on_extraction_result({
            result = response.result,
            tokens = response.tokens,
            prompt = prompt,
            analyzer_context = direct_analysis_context
        })
    end

    local final_result = response.result or {}

    return final_result, nil
end

function extractor:run()
    local success, err = self:initialize()
    if not success then
        return nil, err
    end

    local validation_results, validation_err = self:validate()
    if validation_err then
        return nil, validation_err
    end

    local extraction_result, extraction_err = self:extract()
    if extraction_err then
        return nil, extraction_err
    end

    if self.options.callbacks.on_run_complete then
        self.options.callbacks.on_run_complete({
            validation_results = validation_results,
            extraction_result = extraction_result,
            metrics = self:get_metrics(),
            notes = self.options.shared_context and self.state.notes or {}
        })
    end

    return {
        result = extraction_result,
        analyzer_context = self.analyzer_context,
        metrics = {
            tokens = {
                validation = self.metrics.validation_tokens,
                extraction = self.metrics.extraction_tokens,
                total = self.metrics.total_tokens,
                thinking_tokens = self.metrics.thinking_tokens
            },
            validation_steps = self.metrics.validation_steps_performed,
            excluded_chunks = self.metrics.excluded_chunks,
            additional_queries = self.metrics.additional_queries,
            confidence = self.metrics.confidence_by_step
        },
        notes = self.options.shared_context and self.state.notes or {},
        validation_results = validation_results,
        validation_prompts = self.validation_prompts,
        validation_responses = self.validation_responses,
        extraction_prompt = self.extraction_prompt,
        extraction_response = self.extraction_response
    }, nil
end

function extractor:get_metrics()
    return {
        tokens = {
            validation = self.metrics.validation_tokens,
            extraction = self.metrics.extraction_tokens,
            total = self.metrics.total_tokens,
            thinking_tokens = self.metrics.thinking_tokens
        },
        validation_steps = self.metrics.validation_steps_performed,
        excluded_chunks = self.metrics.excluded_chunks,
        additional_queries = self.metrics.additional_queries,
        confidence = self.metrics.confidence_by_step
    }
end

function extractor:get_state_summary()
    if not self.state then
        return nil
    end

    return self.state:get_state_summary()
end

return extractor