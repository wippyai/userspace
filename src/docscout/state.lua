local embeddings = require("embeddings")
local registry = require("config_registry")

local state = {}
state.__index = state

local function generate_short_id(existing_ids)
    local charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local short_id
    local attempts = 0
    repeat
        short_id = ""
        for _ = 1, 4 do
            local pos = math.random(1, #charset)
            short_id = short_id .. string.sub(charset, pos, pos)
        end
        attempts = attempts + 1
    until not existing_ids[short_id] or attempts > 100
    if attempts > 100 then error("Failed to generate unique short ID after 100 attempts") end
    return short_id
end

function state.new(file_uuid, entry_id)
    math.randomseed(os.time())

    local self = {
        file_uuid = file_uuid,
        entry_id = entry_id,
        entry_config = nil,
        entry_name = nil,
        queries = {},
        all_chunks = {},
        ignored_chunk_ids = {},
        id_mapping = {},
        reverse_id_mapping = {},
        notes = {}
    }
    return setmetatable(self, state)
end

function state:add_note(content, note_type, field_name)
    if not content or type(content) ~= "string" or string.len(content) == 0 then
        return false
    end

    note_type = note_type or "general"

    local note = {
        step = #self.notes + 1,
        content = content,
        type = note_type,
        field_name = field_name,
        timestamp = os.time()
    }

    table.insert(self.notes, note)
    return true
end

function state:get_notes(filter_type, filter_field)
    if not filter_type and not filter_field then
        return self.notes
    end

    local filtered_notes = {}
    for _, note in ipairs(self.notes) do
        local type_match = not filter_type or note.type == filter_type
        local field_match = not filter_field or note.field_name == filter_field

        if type_match and field_match then
            table.insert(filtered_notes, note)
        end
    end

    return filtered_notes
end

function state:get_latest_note(note_type)
    if not note_type then
        if #self.notes > 0 then
            return self.notes[#self.notes]
        end
        return nil
    end

    for i = #self.notes, 1, -1 do
        if self.notes[i].type == note_type then
            return self.notes[i]
        end
    end

    return nil
end

function state:load_entry_config()
    local entry, err = registry.get_entry(self.entry_id)
    if not entry then
        return false, "Failed to load registry entry: " .. (err or "unknown error")
    end

    self.entry_config = entry
    self.entry_name = entry.title or entry.name or "Unnamed Entry"
    return true
end

function state:is_chunk_ignored(short_id)
    return self.ignored_chunk_ids[short_id] == true
end

function state:_get_or_create_short_id(full_uuid)
    if self.reverse_id_mapping[full_uuid] then
        return self.reverse_id_mapping[full_uuid]
    end
    local short_id = generate_short_id(self.id_mapping)
    self.id_mapping[short_id] = full_uuid
    self.reverse_id_mapping[full_uuid] = short_id
    return short_id
end

function state:exclude_chunk_ids(chunk_ids)
    if not chunk_ids or #chunk_ids == 0 then return 0 end

    local count = 0
    for _, id in ipairs(chunk_ids) do
        local short_id = id
        if string.len(id) > 10 then
            short_id = self.reverse_id_mapping[id] or id
        end

        if self.id_mapping[short_id] and not self:is_chunk_ignored(short_id) then
            self.ignored_chunk_ids[short_id] = true
            count = count + 1
        end
    end
    return count
end

function state:run_query(query_text, params)
    params = params or {}
    local limit = params.limit or 5
    local query_type = params.type or "general"
    local field_name = params.field_name

    local search_results, err = embeddings.search(query_text, {
        origin_id = self.file_uuid,
        limit = limit
    })

    if err then
        return nil, "Failed to search document chunks: " .. err
    end

    if not search_results then
         search_results = {}
    end

    local query_chunks = {}
    local chunk_positions = {}

    for i, result in ipairs(search_results) do
        if not result or not result.entry_id or not result.content then
             goto continue_loop
        end

        local full_uuid = result.entry_id
        local short_id = self:_get_or_create_short_id(full_uuid)

        if not self:is_chunk_ignored(short_id) then
            if not self.all_chunks[short_id] then
                self.all_chunks[short_id] = {
                    id = short_id,
                    content = result.content,
                    meta = result.meta
                }
                if result.meta and result.meta.chunk_index then
                    chunk_positions[short_id] = tonumber(result.meta.chunk_index) or 999999 + i
                else
                     chunk_positions[short_id] = 999999 + i
                end
            else
                 if not chunk_positions[short_id] then
                     if self.all_chunks[short_id].meta and self.all_chunks[short_id].meta.chunk_index then
                         chunk_positions[short_id] = tonumber(self.all_chunks[short_id].meta.chunk_index) or 999999 + i
                     else
                         chunk_positions[short_id] = 999999 + i
                     end
                 end
            end

            table.insert(query_chunks, self.all_chunks[short_id])
        end
        ::continue_loop::
    end

    table.sort(query_chunks, function(a, b)
        local a_pos = chunk_positions[a.id]
        local b_pos = chunk_positions[b.id]
        return a_pos < b_pos
    end)

    local query_result = {
        text = query_text,
        type = query_type,
        field_name = field_name,
        chunks = query_chunks
    }

    table.insert(self.queries, query_result)
    return query_result, nil
end

function state:process_prefetch()
    if not self.entry_config or not self.entry_config.prefetch then
        return
    end

    local count = 0
    for _, prefetch_item in ipairs(self.entry_config.prefetch) do
        if type(prefetch_item) == "table" and prefetch_item.description and type(prefetch_item.description) == "string" then
            local chunk_limit = tonumber(prefetch_item.chunks) or 5
            local query_name = prefetch_item.name or ("Prefetch #" .. (_))

            local result, err = self:run_query(prefetch_item.description, {
                limit = chunk_limit,
                type = "prefetch",
                field_name = query_name
            })

            if result then
                count = count + 1
            end
        end
    end
end

function state:process_field_queries()
    if not self.entry_config or not self.entry_config.fields then
        return
    end

    local default_chunk_limit = 5
    if self.entry_config.scouting and self.entry_config.scouting.default_chunk_limit then
        default_chunk_limit = tonumber(self.entry_config.scouting.default_chunk_limit) or 5
    end

    local count = 0
    for field_name, field_config in pairs(self.entry_config.fields) do
        if type(field_config) == "table" and field_config.search_query and type(field_config.search_query) == "string" then
            local field_chunk_limit = field_config.chunks or default_chunk_limit
            field_chunk_limit = tonumber(field_chunk_limit) or default_chunk_limit

            local result, err = self:run_query(field_config.search_query, {
                limit = field_chunk_limit,
                type = "field",
                field_name = field_name
            })

            if result then
                count = count + 1
            end
        end
    end
end

function state:initialize()
    local success, err = self:load_entry_config()
    if not success then
        return false, err
    end

    self:process_prefetch()
    self:process_field_queries()

    return true, nil
end

function state:get_queries_by_type(query_type)
    local result = {}
    for _, query in ipairs(self.queries) do
        if query.type == query_type then
            table.insert(result, query)
        end
    end
    return result
end

function state:get_field_queries(field_name)
    local result = {}
    for _, query in ipairs(self.queries) do
        if query.field_name == field_name then
            table.insert(result, query)
        end
    end
    return result
end

function state:get_field_chunks(field_name)
    local chunks = {}
    local seen_short_ids = {}

    local field_queries = self:get_field_queries(field_name)

    for _, query in ipairs(field_queries) do
        for _, chunk_ref in ipairs(query.chunks or {}) do
            if chunk_ref and chunk_ref.id and not self:is_chunk_ignored(chunk_ref.id) and not seen_short_ids[chunk_ref.id] then
                table.insert(chunks, chunk_ref)
                seen_short_ids[chunk_ref.id] = true
            end
        end
    end

    return chunks
end

function state:count_all_unique_chunks()
    local count = 0
    for _ in pairs(self.all_chunks) do
        count = count + 1
    end
    return count
end

function state:count_unique_chunks()
    local count = 0
    for short_id, _ in pairs(self.all_chunks) do
        if not self:is_chunk_ignored(short_id) then
            count = count + 1
        end
    end
    return count
end

function state:get_state_summary()
    local active_queries = {}
    for _, query in ipairs(self.queries) do
        local active_chunks_in_query = {}
        for _, chunk_ref in ipairs(query.chunks or {}) do
            if chunk_ref and chunk_ref.id and not self:is_chunk_ignored(chunk_ref.id) then
                table.insert(active_chunks_in_query, chunk_ref)
            end
        end

        if #active_chunks_in_query > 0 then
             local query_copy = {
                text = query.text,
                type = query.type,
                field_name = query.field_name,
                chunks = active_chunks_in_query
             }
             table.insert(active_queries, query_copy)
        end
    end

     local ignored_count = 0
     for _ in pairs(self.ignored_chunk_ids) do ignored_count = ignored_count + 1 end

    return {
        file_uuid = self.file_uuid,
        entry_id = self.entry_id,
        entry_name = self.entry_name,
        total_queries_run = #self.queries,
        active_queries_count = #active_queries,
        total_unique_chunks_collected = self:count_all_unique_chunks(),
        active_unique_chunks = self:count_unique_chunks(),
        ignored_chunk_count = ignored_count,
        notes_count = #self.notes,
        notes = self.notes
    }
end

return state