local sql = require("sql")
local json = require("json")
local consts = require("consts")

local APP_DB = "app:db"

local function normalize_vector_distances(rows, db_type)
    if not rows or #rows == 0 then
        return rows
    end

    for i = 1, #rows do
        local row = rows[i]
        if db_type == sql.type.POSTGRES then
            if row.vector_distance then
                row.similarity = 1 - (row.vector_distance / 2)
            end
        elseif db_type == sql.type.SQLITE then
            if row.distance then
                row.similarity = math.exp(-row.distance)
                row.vector_distance = row.distance
                row.distance = nil
            end
        end
    end

    return rows
end

local function parse_metadata(rows)
    if not rows or #rows == 0 then
        return rows
    end

    for i = 1, #rows do
        local row = rows[i]
        if row.metadata then
            local parsed, err = json.decode(row.metadata)
            if err then
                row.metadata = {}
            else
                row.metadata = parsed
            end
        else
            row.metadata = {}
        end
    end
    return rows
end

local function get_db()
    local db, err = sql.get(APP_DB)
    if err then
        error("Failed to connect to database: " .. err)
    end
    return db
end

local function get_db_type(db)
    local db_type, err = db:type()
    if err then
        error("Failed to get database type: " .. err)
    end
    return db_type
end

local function vector_to_string(vec)
    return "[" .. table.concat(vec, ",") .. "]"
end

local function normalize_args(args, arg_count)
    if arg_count == 1 and type(args[1]) == "table" and not getmetatable(args[1]) then
        return args[1]
    else
        return args
    end
end

local reader = {}
local methods = {}
local reader_mt = { __index = methods }

function methods:_copy()
    local new_instance = {}
    for k, v in pairs(self) do
        new_instance[k] = v
    end
    return setmetatable(new_instance, reader_mt)
end

function reader.for_kb(kb_id)
    if not kb_id or kb_id == "" then
        error(consts.ERROR.INVALID_KB_ID)
    end

    local instance = {
        _kb_id = kb_id,
        _path_prefix = nil,
        _exact_path = nil,
        _parent_id = nil,
        _node_types = nil,
        _search_query = nil,
        _vector_embedding = nil,
        _include_content = true,
        _include_metadata = true,
        _order_by_vector = false,
        _limit = nil,
        _offset = nil,
    }
    return setmetatable(instance, reader_mt)
end

function methods:under(path_prefix)
    local new_instance = self:_copy()
    new_instance._path_prefix = path_prefix
    new_instance._exact_path = nil
    return new_instance
end

function methods:at_path(exact_path)
    local new_instance = self:_copy()
    new_instance._exact_path = exact_path
    new_instance._path_prefix = nil
    return new_instance
end

function methods:children_of(parent_id)
    local new_instance = self:_copy()
    new_instance._parent_id = parent_id
    return new_instance
end

function methods:with_parent(parent_id)
    return self:children_of(parent_id)
end

function methods:of_type(node_type)
    local new_instance = self:_copy()
    new_instance._node_types = {node_type}
    return new_instance
end

function methods:of_types(...)
    local args = {...}
    local count = select("#", ...)
    local new_instance = self:_copy()
    new_instance._node_types = normalize_args(args, count)
    return new_instance
end

function methods:search(query)
    local new_instance = self:_copy()
    if query and query ~= "" and string.match(query, "%S") then
        new_instance._search_query = query
    else
        new_instance._search_query = nil
    end
    return new_instance
end

function methods:near_vector(embedding)
    if type(embedding) ~= "table" or #embedding ~= consts.VECTOR_DIMENSIONS then
        error(consts.ERROR.INVALID_EMBEDDING_DIM)
    end
    local new_instance = self:_copy()
    new_instance._vector_embedding = embedding
    new_instance._order_by_vector = true
    return new_instance
end

function methods:limit(n)
    if type(n) ~= "number" or n <= 0 then
        error("Limit must be a positive number")
    end
    local new_instance = self:_copy()
    new_instance._limit = n
    return new_instance
end

function methods:offset(n)
    if type(n) ~= "number" or n < 0 then
        error("Offset must be a non-negative number")
    end
    local new_instance = self:_copy()
    new_instance._offset = n
    return new_instance
end

function methods:include_content()
    local new_instance = self:_copy()
    new_instance._include_content = true
    return new_instance
end

function methods:exclude_content()
    local new_instance = self:_copy()
    new_instance._include_content = false
    return new_instance
end

function methods:include_metadata()
    local new_instance = self:_copy()
    new_instance._include_metadata = true
    return new_instance
end

function methods:exclude_metadata()
    local new_instance = self:_copy()
    new_instance._include_metadata = false
    return new_instance
end

function methods:_execute_sqlite_vector_search()
    local db = get_db()

    local select_fields = {
        "e.node_id as id",
        "e.kb_id",
        "e.parent_id",
        "e.path",
        "e.node_type",
        "n.value",
        "n.created_at",
        "n.updated_at",
        "e.distance"
    }

    if self._include_content then
        table.insert(select_fields, "n.content")
        table.insert(select_fields, "n.content_type")
    end

    if self._include_metadata then
        table.insert(select_fields, "n.metadata")
    end

    local query = "SELECT " .. table.concat(select_fields, ", ") .. " " ..
                  "FROM kb_node_embeddings e " ..
                  "LEFT JOIN kb_nodes n ON n.id = e.node_id " ..
                  "WHERE e.embedding MATCH ? " ..
                  "AND e.kb_id = ? " ..
                  "AND e.k = ?"

    local params = table.create(10, 0)
    params[1] = vector_to_string(self._vector_embedding)
    params[2] = self._kb_id
    params[3] = self._limit or 100

    local param_count = 3

    if self._exact_path then
        query = query .. " AND e.path = ?"
        param_count = param_count + 1
        params[param_count] = self._exact_path
    elseif self._path_prefix then
        query = query .. " AND e.path LIKE ?"
        param_count = param_count + 1
        params[param_count] = self._path_prefix .. ".%"
    end

    if self._parent_id then
        query = query .. " AND e.parent_id = ?"
        param_count = param_count + 1
        params[param_count] = self._parent_id
    end

    if self._node_types and #self._node_types > 0 then
        if #self._node_types == 1 then
            query = query .. " AND e.node_type = ?"
            param_count = param_count + 1
            params[param_count] = self._node_types[1]
        else
            local placeholders = table.create(#self._node_types, 0)
            for i = 1, #self._node_types do
                placeholders[i] = "?"
                param_count = param_count + 1
                params[param_count] = self._node_types[i]
            end
            query = query .. " AND e.node_type IN (" .. table.concat(placeholders, ",") .. ")"
        end
    end

    if self._search_query then
        query = query .. " AND e.node_id IN (SELECT node_id FROM kb_nodes_fts WHERE kb_nodes_fts MATCH ?)"
        param_count = param_count + 1
        params[param_count] = self._search_query
    end

    query = query .. " ORDER BY e.distance"

    if self._offset then
        query = query .. " OFFSET " .. self._offset
    end

    local used_params = {}
    for i = 1, param_count do
        used_params[i] = params[i]
    end

    local results, err = db:query(query, used_params)
    db:release()

    if err then
        return nil, err
    end

    for i = 1, #results do
        local row = results[i]
        if row.distance then
            row.similarity = math.exp(-row.distance)
        end
    end

    return results
end

function methods:_build_query(for_count)
    local db = get_db()
    local db_type = get_db_type(db)
    db:release()

    if self._vector_embedding and not self._limit and not for_count then
        error("Vector search requires limit() - use :near_vector(...):limit(n):all()")
    end

    if self._vector_embedding and db_type == sql.type.SQLITE and not for_count then
        return nil, db_type
    end

    local query_builder

    if for_count then
        query_builder = sql.builder.select("COUNT(*) as count")
    else
        local select_fields = {
            "n.id",
            "n.kb_id",
            "n.parent_id",
            "n.path",
            "n.node_type",
            "n.value",
            "n.created_at",
            "n.updated_at"
        }

        if self._include_content then
            table.insert(select_fields, "n.content")
            table.insert(select_fields, "n.content_type")
        end

        if self._include_metadata then
            table.insert(select_fields, "n.metadata")
        end

        if self._vector_embedding and db_type == sql.type.POSTGRES then
            table.insert(
                select_fields,
                "e.embedding <=> ('" .. vector_to_string(self._vector_embedding) .. "'::vector) as vector_distance"
            )
        end

        query_builder = sql.builder.select(unpack(select_fields))
    end

    query_builder = query_builder:from("kb_nodes n")

    if self._vector_embedding and not for_count and db_type == sql.type.POSTGRES then
        query_builder = query_builder:join("kb_node_embeddings e ON n.id = e.node_id")
    end

    query_builder = query_builder:where("n.kb_id = ?", self._kb_id)

    if self._exact_path then
        query_builder = query_builder:where("n.path = ?", self._exact_path)
    elseif self._path_prefix then
        query_builder = query_builder:where("n.path LIKE ?", self._path_prefix .. ".%")
    end

    if self._parent_id then
        query_builder = query_builder:where("n.parent_id = ?", self._parent_id)
    end

    if self._node_types and #self._node_types > 0 then
        if #self._node_types == 1 then
            query_builder = query_builder:where("n.node_type = ?", self._node_types[1])
        else
            local conditions = table.create(#self._node_types, 0)
            for i = 1, #self._node_types do
                conditions[i] = "?"
            end
            query_builder = query_builder:where(
                "n.node_type IN (" .. table.concat(conditions, ",") .. ")",
                unpack(self._node_types)
            )
        end
    end

    if self._vector_embedding and not for_count and db_type == sql.type.POSTGRES then
        query_builder = query_builder:where("e.embedding <=> ? <= 2", vector_to_string(self._vector_embedding))
    end

    if self._search_query and self._search_query ~= "" and string.match(self._search_query, "%S") then
        if db_type == sql.type.POSTGRES then
            query_builder = query_builder:where("n.search_vector @@ to_tsquery('english', ?)", self._search_query)
        elseif db_type == sql.type.SQLITE then
            query_builder = query_builder:where(
                "n.id IN (SELECT node_id FROM kb_nodes_fts WHERE kb_nodes_fts MATCH ?)",
                self._search_query
            )
        end
    end

    if self._limit and not for_count then
        query_builder = query_builder:limit(self._limit)
    end

    if self._offset and not for_count then
        query_builder = query_builder:offset(self._offset)
    end

    if not for_count then
        if self._order_by_vector and self._vector_embedding and db_type == sql.type.POSTGRES then
            query_builder = query_builder:order_by("vector_distance ASC")
        else
            query_builder = query_builder:order_by("n.created_at ASC")
        end
    end

    return query_builder, db_type
end

function methods:all()
    local query_builder, db_type = self:_build_query()

    local results, err

    if self._vector_embedding and db_type == sql.type.SQLITE then
        results, err = self:_execute_sqlite_vector_search()
    else
        local db = get_db()
        local executor = query_builder:run_with(db)
        results, err = executor:query()
        db:release()
    end

    if err then
        return nil, err
    end

    if self._include_metadata then
        results = parse_metadata(results)
    end

    if self._vector_embedding then
        results = normalize_vector_distances(results, db_type)
    end

    return results
end

function methods:first(n)
    local new_instance = self:_copy()
    new_instance._limit = n
    return new_instance:all()
end

function methods:one()
    local results, err = self:first(1)
    if err then
        return nil, err
    end
    return results and results[1] or nil
end

function methods:count()
    local query_builder, db_type = self:_build_query(true)

    local db = get_db()
    local executor = query_builder:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, err
    end

    return results[1].count
end

function methods:exists()
    local count, err = self:count()
    if err then
        return false, err
    end
    return count > 0
end

-- ============================================================================
-- EMBED OPERATIONS READER
-- ============================================================================

local ops_methods = {}
local ops_mt = { __index = ops_methods }

function reader.for_operations(component_id)
    if not component_id or component_id == "" then
        error(consts.ERROR.INVALID_COMPONENT_ID)
    end

    local instance = {
        _component_id = component_id,
        _status = nil,
        _limit = nil,
        _offset = nil,
    }
    return setmetatable(instance, ops_mt)
end

function ops_methods:_copy()
    local new_instance = {}
    for k, v in pairs(self) do
        new_instance[k] = v
    end
    return setmetatable(new_instance, ops_mt)
end

function ops_methods:with_status(status)
    local new_instance = self:_copy()
    new_instance._status = status
    return new_instance
end

function ops_methods:limit(n)
    local new_instance = self:_copy()
    new_instance._limit = n
    return new_instance
end

function ops_methods:offset(n)
    local new_instance = self:_copy()
    new_instance._offset = n
    return new_instance
end

function ops_methods:all()
    local db = get_db()

    local query = sql.builder.select("id", "component_id", "upload_uuid", "status", "error", "ops_executed", "created_at", "updated_at")
        :from("kb_embed_operations")
        :where("component_id = ?", self._component_id)
        :order_by("created_at DESC")

    if self._status then
        query = query:where("status = ?", self._status)
    end

    if self._limit then
        query = query:limit(self._limit)
    end

    if self._offset then
        query = query:offset(self._offset)
    end

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to list operations: " .. err
    end

    return results
end

function ops_methods:count()
    local db = get_db()

    local query = sql.builder.select("COUNT(*) as count")
        :from("kb_embed_operations")
        :where("component_id = ?", self._component_id)

    if self._status then
        query = query:where("status = ?", self._status)
    end

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to count operations: " .. err
    end

    return results[1].count
end

function reader.get_operation(operation_id)
    if not operation_id or operation_id == "" then
        error("Operation ID is required")
    end

    local db = get_db()

    local query = sql.builder.select("id", "component_id", "upload_uuid", "status", "error", "ops_executed", "created_at", "updated_at")
        :from("kb_embed_operations")
        :where("id = ?", operation_id)
        :limit(1)

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to get operation: " .. err
    end

    if #results == 0 then
        return nil, "Operation not found"
    end

    return results[1]
end

return reader
