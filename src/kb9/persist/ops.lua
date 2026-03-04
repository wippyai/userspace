local sql = require("sql")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local consts = require("consts")

local handlers = {}

local function now_utc()
    return time.now():utc():format(time.RFC3339NANO)
end

local function now_unix()
    return time.now():unix()
end

local function get_db_type(tx)
    local db_type, err = tx:db_type()
    if err then
        return nil, "Failed to get database type: " .. err
    end
    return db_type
end

local function format_path_segment(num)
    return string.format("%0" .. consts.PATH.SEGMENT_WIDTH .. "d", num)
end

local function parse_last_segment(path)
    if not path then return 0 end
    local segments = {}
    for segment in string.gmatch(path, "[^" .. consts.PATH.SEPARATOR .. "]+") do
        table.insert(segments, segment)
    end
    if #segments == 0 then return 0 end
    return tonumber(segments[#segments]) or 0
end

local function generate_next_path(tx, kb_id, parent_id, parent_path)
    local query
    if not parent_id then
        query = sql.builder.select("MAX(path) as max_path")
            :from("kb_nodes")
            :where("kb_id = ?", kb_id)
            :where("parent_id IS NULL")
    else
        local pattern = parent_path .. consts.PATH.SEPARATOR .. "%"
        query = sql.builder.select("MAX(path) as max_path")
            :from("kb_nodes")
            :where("kb_id = ?", kb_id)
            :where("parent_id = ?", parent_id)
            :where("path LIKE ?", pattern)
    end

    local executor = query:run_with(tx)
    local results, err = executor:query()

    if err then
        return nil, "Failed to query max path: " .. err
    end

    local max_path = results[1] and results[1].max_path
    local last_num = parse_last_segment(max_path)
    local next_num = last_num + consts.PATH.INCREMENT
    local next_segment = format_path_segment(next_num)

    if parent_path then
        return parent_path .. consts.PATH.SEPARATOR .. next_segment
    else
        return next_segment
    end
end

local function sync_fts_sqlite(tx, node_id, content, node_type)
    local delete_query = sql.builder.delete("kb_nodes_fts")
        :where("node_id = ?", node_id)

    local executor = delete_query:run_with(tx)
    local _, err = executor:exec()
    if err then
        return "Failed to delete FTS entry: " .. err
    end

    if content and content ~= "" then
        local insert_query = sql.builder.insert("kb_nodes_fts")
            :set_map({
                node_id = node_id,
                content = content,
                node_type = node_type or ""
            })

        executor = insert_query:run_with(tx)
        _, err = executor:exec()
        if err then
            return "Failed to insert FTS entry: " .. err
        end
    end

    return nil
end

local function vector_to_string(vec)
    return "[" .. table.concat(vec, ",") .. "]"
end

local function validate_embedding_vector(embedding)
    if type(embedding) ~= "table" then
        return false, "Embedding must be an array"
    end

    if #embedding ~= consts.VECTOR_DIMENSIONS then
        return false, "Embedding must have " .. consts.VECTOR_DIMENSIONS .. " dimensions"
    end

    for i, val in ipairs(embedding) do
        if type(val) ~= "number" then
            return false, "Embedding value at index " .. i .. " must be a number"
        end
    end

    return true
end

-- Note: This function is disabled due to vec0 limitations with updating metadata columns
local function sync_embedding_fields_sqlite(tx, node_id, kb_id)
    -- SQLite vec0 virtual tables don't support updating metadata columns
    -- This operation would fail with "UPDATE on partition key columns are not supported yet"
    -- The fields are set correctly during initial embedding creation
    return nil
end

-- Helper function to convert NULL values to empty strings for vec0 metadata columns
local function vec0_safe_string(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

handlers[consts.COMMAND_TYPES.CREATE_COMPONENT] = function(tx, kb_id, op_id, command)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, consts.ERROR.INVALID_COMPONENT_ID
    end

    local id = payload.id or uuid.v7()
    local config = payload.config or {}

    if type(config) == "table" then
        local encoded, err = json.encode(config)
        if err then
            return nil, "Failed to encode config: " .. err
        end
        config = encoded
    end

    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    local now_timestamp
    if db_type == sql.type.SQLITE then
        now_timestamp = sql.as.int(now_unix())
    else
        now_timestamp = now_utc()
    end

    local insert_query = sql.builder.insert("kb_components")
        :set_map({
            id = id,
            component_id = payload.component_id,
            config = config,
            created_at = now_timestamp,
            updated_at = now_timestamp
        })

    local executor = insert_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to create component: " .. err
    end

    return {
        id = id,
        component_id = payload.component_id,
        op_id = op_id
    }
end

handlers[consts.COMMAND_TYPES.UPDATE_COMPONENT] = function(tx, kb_id, op_id, command)
    local payload = command.payload or {}

    if not payload.id then
        return nil, consts.ERROR.INVALID_COMPONENT_ID
    end

    if not payload.config then
        return nil, "Config is required for update"
    end

    local config = payload.config
    if type(config) == "table" then
        local encoded, err = json.encode(config)
        if err then
            return nil, "Failed to encode config: " .. err
        end
        config = encoded
    end

    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    local now_timestamp
    if db_type == sql.type.SQLITE then
        now_timestamp = sql.as.int(now_unix())
    else
        now_timestamp = now_utc()
    end

    local update_query = sql.builder.update("kb_components")
        :set("config", config)
        :set("updated_at", now_timestamp)
        :where("id = ?", payload.id)

    local executor = update_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to update component: " .. err
    end

    if result.rows_affected == 0 then
        return nil, consts.ERROR.COMPONENT_NOT_FOUND
    end

    return {
        id = payload.id,
        op_id = op_id
    }
end

handlers[consts.COMMAND_TYPES.DELETE_COMPONENT] = function(tx, kb_id, op_id, command)
    local payload = command.payload or {}

    if not payload.id then
        return nil, consts.ERROR.INVALID_COMPONENT_ID
    end

    local delete_query = sql.builder.delete("kb_components")
        :where("id = ?", payload.id)

    local executor = delete_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to delete component: " .. err
    end

    if result.rows_affected == 0 then
        return nil, consts.ERROR.COMPONENT_NOT_FOUND
    end

    return {
        id = payload.id,
        deleted = true,
        op_id = op_id
    }
end

handlers[consts.COMMAND_TYPES.CREATE_NODE] = function(tx, kb_id, op_id, command)
    if not kb_id then
        return nil, consts.ERROR.INVALID_KB_ID
    end

    local payload = command.payload or {}

    if not payload.node_type then
        return nil, "Node type is required"
    end

    local node_id = payload.id or uuid.v7()
    local parent_id = payload.parent_id or sql.as.null()
    local parent_path = nil

    if payload.parent_id then
        local parent_query = sql.builder.select("path")
            :from("kb_nodes")
            :where("id = ?", payload.parent_id)
            :where("kb_id = ?", kb_id)

        local executor = parent_query:run_with(tx)
        local results, err = executor:query()

        if err then
            return nil, "Failed to get parent node: " .. err
        end

        if #results == 0 then
            return nil, consts.ERROR.PARENT_NOT_FOUND
        end

        parent_path = results[1].path
    end

    local path, err = generate_next_path(tx, kb_id, payload.parent_id, parent_path)
    if err then
        return nil, err
    end

    local metadata = payload.metadata or {}
    if type(metadata) == "table" then
        local encoded, err = json.encode(metadata)
        if err then
            return nil, "Failed to encode metadata: " .. err
        end
        metadata = encoded
    end

    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    local now_timestamp
    if db_type == sql.type.SQLITE then
        now_timestamp = sql.as.int(now_unix())
    else
        now_timestamp = now_utc()
    end

    local insert_data = {
        id = node_id,
        kb_id = kb_id,
        parent_id = parent_id,
        path = path,
        node_type = payload.node_type,
        content = payload.content or sql.as.null(),
        content_type = payload.content_type or "text/plain",
        value = payload.value or sql.as.null(),
        metadata = metadata,
        created_at = now_timestamp,
        updated_at = now_timestamp
    }

    local insert_query = sql.builder.insert("kb_nodes")
        :set_map(insert_data)

    local executor = insert_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to create node: " .. err
    end

    if db_type == sql.type.SQLITE and payload.content then
        err = sync_fts_sqlite(tx, node_id, payload.content, payload.node_type)
        if err then
            return nil, err
        end
    end

    return {
        id = node_id,
        path = path,
        op_id = op_id
    }
end

handlers[consts.COMMAND_TYPES.UPDATE_NODE] = function(tx, kb_id, op_id, command)
    if not kb_id then
        return nil, consts.ERROR.INVALID_KB_ID
    end

    local payload = command.payload or {}

    if not payload.id then
        return nil, consts.ERROR.INVALID_NODE_ID
    end

    local update_query = sql.builder.update("kb_nodes")
        :where("id = ?", payload.id)
        :where("kb_id = ?", kb_id)

    local has_update = false
    local sync_embeddings = false

    if payload.node_type then
        update_query = update_query:set("node_type", payload.node_type)
        has_update = true
        sync_embeddings = true
    end

    if payload.content ~= nil then
        update_query = update_query:set("content", payload.content or sql.as.null())
        has_update = true
    end

    if payload.content_type then
        update_query = update_query:set("content_type", payload.content_type)
        has_update = true
        sync_embeddings = true
    end

    if payload.value ~= nil then
        update_query = update_query:set("value", payload.value or sql.as.null())
        has_update = true
    end

    if payload.metadata then
        local metadata = payload.metadata
        if type(metadata) == "table" then
            local encoded, err = json.encode(metadata)
            if err then
                return nil, "Failed to encode metadata: " .. err
            end
            metadata = encoded
        end
        update_query = update_query:set("metadata", metadata)
        has_update = true
    end

    if not has_update then
        return {
            id = payload.id,
            changed = false,
            op_id = op_id
        }
    end

    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    local now_timestamp
    if db_type == sql.type.SQLITE then
        now_timestamp = sql.as.int(now_unix())
    else
        now_timestamp = now_utc()
    end

    update_query = update_query:set("updated_at", now_timestamp)

    local executor = update_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to update node: " .. err
    end

    if result.rows_affected == 0 then
        return nil, consts.ERROR.NODE_NOT_FOUND
    end

    if db_type == sql.type.SQLITE then
        if payload.content ~= nil then
            err = sync_fts_sqlite(tx, payload.id, payload.content, payload.node_type)
            if err then
                return nil, err
            end
        end

        -- Note: Embedding field sync is disabled due to vec0 limitations
        -- The sync_embedding_fields_sqlite function is now a no-op
        if sync_embeddings then
            err = sync_embedding_fields_sqlite(tx, payload.id, kb_id)
            if err then
                return nil, err
            end
        end
    end

    return {
        id = payload.id,
        changed = true,
        op_id = op_id
    }
end

handlers[consts.COMMAND_TYPES.DELETE_NODE] = function(tx, kb_id, op_id, command)
    if not kb_id then
        return nil, consts.ERROR.INVALID_KB_ID
    end

    local payload = command.payload or {}

    if not payload.id then
        return nil, consts.ERROR.INVALID_NODE_ID
    end

    -- First check if node exists and get its path
    local path_query = sql.builder.select("path")
        :from("kb_nodes")
        :where("id = ?", payload.id)
        :where("kb_id = ?", kb_id)

    local executor = path_query:run_with(tx)
    local results, err = executor:query()

    if err then
        return nil, "Failed to get node path: " .. err
    end

    if #results == 0 then
        -- Node doesn't exist - this is OK (might have been deleted by foreign key cascade)
        return {
            id = payload.id,
            deleted = false,
            nodes_deleted = 0,
            op_id = op_id,
            already_deleted = true
        }
    end

    local path = results[1].path

    -- Get all node IDs that will be deleted (for embedding cleanup)
    local nodes_to_delete_query = sql.builder.select("id")
        :from("kb_nodes")
        :where("kb_id = ?", kb_id)
        :where(sql.builder.or_({
            sql.builder.eq({path = path}),
            sql.builder.expr("path LIKE ?", path .. consts.PATH.SEPARATOR .. "%")
        }))

    executor = nodes_to_delete_query:run_with(tx)
    local nodes_to_delete, err = executor:query()

    if err then
        return nil, "Failed to get nodes to delete: " .. err
    end

    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    -- CRITICAL: Delete embeddings FIRST for all nodes that will be deleted
    for _, node in ipairs(nodes_to_delete) do
        local node_id = node.id

        if db_type == sql.type.POSTGRES then
            local delete_embeddings = sql.builder.delete("kb_node_embeddings")
                :where("node_id = ?", node_id)
                :where("kb_id = ?", kb_id)

            executor = delete_embeddings:run_with(tx)
            local _, err = executor:exec()
            if err then
                return nil, "Failed to delete embeddings for node " .. node_id .. ": " .. err
            end
        else
            -- SQLite with raw SQL for virtual table
            local delete_sql = "DELETE FROM kb_node_embeddings WHERE node_id = ? AND kb_id = ?"
            local _, err = tx:execute(delete_sql, {node_id, kb_id})
            if err then
                return nil, "Failed to delete embeddings for node " .. node_id .. ": " .. err
            end
        end
    end

    -- Delete from FTS (SQLite only)
    if db_type == sql.type.SQLITE then
        for _, node in ipairs(nodes_to_delete) do
            local fts_delete = sql.builder.delete("kb_nodes_fts")
                :where("node_id = ?", node.id)

            executor = fts_delete:run_with(tx)
            local _, err = executor:exec()
            -- Continue even if FTS delete fails (non-critical)
        end
    end

    -- Finally delete the nodes
    local delete_query = sql.builder.delete("kb_nodes")
        :where("kb_id = ?", kb_id)
        :where(sql.builder.or_({
            sql.builder.eq({path = path}),
            sql.builder.expr("path LIKE ?", path .. consts.PATH.SEPARATOR .. "%")
        }))

    executor = delete_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to delete nodes: " .. err
    end

    return {
        id = payload.id,
        deleted = true,
        nodes_deleted = result.rows_affected,
        op_id = op_id
    }
end

handlers[consts.COMMAND_TYPES.MOVE_NODE] = function(tx, kb_id, op_id, command)
    return nil, "MOVE_NODE not implemented yet"
end

handlers[consts.COMMAND_TYPES.UPSERT_EMBEDDING] = function(tx, kb_id, op_id, command)
    if not kb_id then
        return nil, consts.ERROR.INVALID_KB_ID
    end

    local payload = command.payload or {}

    if not payload.node_id then
        return nil, consts.ERROR.INVALID_NODE_ID
    end

    if not payload.embedding then
        return nil, consts.ERROR.INVALID_EMBEDDING
    end

    local valid, err = validate_embedding_vector(payload.embedding)
    if not valid then
        return nil, err
    end

    local model_name = payload.model_name or "default"
    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    local now_timestamp
    if db_type == sql.type.SQLITE then
        now_timestamp = sql.as.int(now_unix())
    else
        now_timestamp = now_utc()
    end

    local embedding_vector = vector_to_string(payload.embedding)

    if db_type == sql.type.POSTGRES then
        -- PostgreSQL implementation (no duplicated fields)
        local check_query = sql.builder.select("id")
            :from("kb_node_embeddings")
            :where("node_id = ?", payload.node_id)
            :where("kb_id = ?", kb_id)
            :where("model_name = ?", model_name)

        local executor = check_query:run_with(tx)
        local results, err = executor:query()

        if err then
            return nil, "Failed to check existing embedding: " .. err
        end

        if #results > 0 then
            -- Update existing embedding
            local existing_id = results[1].id
            local update_query = sql.builder.update("kb_node_embeddings")
                :set("embedding", embedding_vector)
                :set("created_at", now_timestamp)
                :where("id = ?", existing_id)

            executor = update_query:run_with(tx)
            local result, err = executor:exec()

            if err then
                return nil, "Failed to update embedding: " .. err
            end

            return {
                id = existing_id,
                node_id = payload.node_id,
                updated = true,
                op_id = op_id
            }
        else
            -- Insert new embedding
            local embedding_id = uuid.v7()
            local insert_query = sql.builder.insert("kb_node_embeddings")
                :set_map({
                    id = embedding_id,
                    node_id = payload.node_id,
                    kb_id = kb_id,
                    model_name = model_name,
                    embedding = embedding_vector,
                    created_at = now_timestamp
                })

            executor = insert_query:run_with(tx)
            local result, err = executor:exec()

            if err then
                return nil, "Failed to insert embedding: " .. err
            end

            return {
                id = embedding_id,
                node_id = payload.node_id,
                created = true,
                op_id = op_id
            }
        end
    else
        -- SQLite implementation (with duplicated fields)
        -- First get the node data for the duplicated fields
        local node_query = sql.builder.select("node_type", "parent_id", "path", "content_type")
            :from("kb_nodes")
            :where("id = ?", payload.node_id)
            :where("kb_id = ?", kb_id)

        local executor = node_query:run_with(tx)
        local node_results, err = executor:query()

        if err then
            return nil, "Failed to get node data: " .. err
        end

        if #node_results == 0 then
            return nil, "Node not found for embedding"
        end

        local node_data = node_results[1]

        -- Check if embedding exists using raw SQL for virtual table
        local check_sql = [[
            SELECT id FROM kb_node_embeddings
            WHERE node_id = ? AND kb_id = ? AND model_name = ?
        ]]

        local existing_embeddings, err = tx:query(check_sql, {payload.node_id, kb_id, model_name})
        if err then
            return nil, "Failed to check existing embedding: " .. err
        end

        if #existing_embeddings > 0 then
            -- Update existing embedding using tx:execute
            local existing_id = existing_embeddings[1].id
            local update_sql = [[
                UPDATE kb_node_embeddings
                SET embedding = ?, node_type = ?, parent_id = ?, path = ?, content_type = ?, created_at = ?
                WHERE id = ?
            ]]

            -- Convert NULL values to safe strings for vec0 metadata columns
            local update_data = {
                embedding_vector,
                vec0_safe_string(node_data.node_type),
                vec0_safe_string(node_data.parent_id),
                vec0_safe_string(node_data.path),
                vec0_safe_string(node_data.content_type),
                sql.as.int(now_timestamp), -- Convert to integer for vec0
                existing_id
            }

            local result, err = tx:execute(update_sql, update_data)

            if err then
                return nil, "Failed to update embedding: " .. err
            end

            return {
                id = existing_id,
                node_id = payload.node_id,
                updated = true,
                op_id = op_id
            }
        else
            -- Insert new embedding using tx:execute
            local embedding_id = uuid.v7()
            local insert_sql = [[
                INSERT INTO kb_node_embeddings (
                    id, node_id, kb_id, model_name, node_type, parent_id, path, content_type, created_at, embedding
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]]

            -- Convert NULL values to safe strings for vec0 metadata columns
            local insert_data = {
                embedding_id,
                payload.node_id,
                kb_id,
                model_name,
                vec0_safe_string(node_data.node_type),
                vec0_safe_string(node_data.parent_id),
                vec0_safe_string(node_data.path),
                vec0_safe_string(node_data.content_type),
                sql.as.int(now_timestamp), -- Convert to integer for vec0
                embedding_vector
            }

            local result, err = tx:execute(insert_sql, insert_data)

            if err then
                return nil, "Failed to insert embedding: " .. err
            end

            return {
                id = embedding_id,
                node_id = payload.node_id,
                created = true,
                op_id = op_id
            }
        end
    end
end

handlers[consts.COMMAND_TYPES.DELETE_EMBEDDING] = function(tx, kb_id, op_id, command)
    if not kb_id then
        return nil, consts.ERROR.INVALID_KB_ID
    end

    local payload = command.payload or {}

    if not payload.node_id then
        return nil, consts.ERROR.INVALID_NODE_ID
    end

    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    if db_type == sql.type.POSTGRES then
        local delete_query = sql.builder.delete("kb_node_embeddings")
            :where("node_id = ?", payload.node_id)
            :where("kb_id = ?", kb_id)

        if payload.model_name then
            delete_query = delete_query:where("model_name = ?", payload.model_name)
        end

        local executor = delete_query:run_with(tx)
        local result, err = executor:exec()

        if err then
            return nil, "Failed to delete embedding: " .. err
        end

        return {
            node_id = payload.node_id,
            deleted = true,
            embeddings_deleted = result.rows_affected,
            op_id = op_id
        }
    else
        -- SQLite with raw SQL for virtual table - use tx:execute
        local delete_sql = [[
            DELETE FROM kb_node_embeddings
            WHERE node_id = ? AND kb_id = ?
        ]]
        local params = {payload.node_id, kb_id}

        if payload.model_name then
            delete_sql = delete_sql .. " AND model_name = ?"
            table.insert(params, payload.model_name)
        end

        local result, err = tx:execute(delete_sql, params)

        if err then
            return nil, "Failed to delete embedding: " .. err
        end

        return {
            node_id = payload.node_id,
            deleted = true,
            embeddings_deleted = 1, -- SQLite doesn't return affected rows for virtual tables
            op_id = op_id
        }
    end
end

handlers[consts.COMMAND_TYPES.DELETE_NODES] = function(tx, kb_id, op_id, command)
    if not kb_id then
        return nil, consts.ERROR.INVALID_KB_ID
    end

    local payload = command.payload or {}

    if not payload.ids or type(payload.ids) ~= "table" or #payload.ids == 0 then
        return nil, "Node IDs array is required"
    end

    local total_deleted = 0
    local deleted_ids = {}

    -- Use the fixed DELETE_NODE for each node
    for _, node_id in ipairs(payload.ids) do
        local delete_cmd = {
            type = consts.COMMAND_TYPES.DELETE_NODE,
            payload = { id = node_id }
        }

        local result, err = handlers[consts.COMMAND_TYPES.DELETE_NODE](tx, kb_id, op_id, delete_cmd)

        if err then
            return nil, "Failed to delete node " .. node_id .. ": " .. err
        end

        if result then
            if result.deleted then
                total_deleted = total_deleted + result.nodes_deleted
                table.insert(deleted_ids, node_id)
            elseif result.already_deleted then
                -- Node was already deleted (e.g., by foreign key cascade) - this is OK
                table.insert(deleted_ids, node_id)
            end
        end
    end

    return {
        ids = deleted_ids,
        total_deleted = total_deleted,
        op_id = op_id
    }
end

-- ============================================================================
-- EMBED OPERATION TRACKING
-- ============================================================================

handlers[consts.COMMAND_TYPES.CREATE_EMBED_OPERATION] = function(tx, kb_id, op_id, command)
    local payload = command.payload or {}

    if not payload.id or payload.id == "" then
        return nil, "Operation ID is required"
    end

    if not payload.component_id or payload.component_id == "" then
        return nil, consts.ERROR.INVALID_COMPONENT_ID
    end

    if not payload.upload_uuid or payload.upload_uuid == "" then
        return nil, "upload_uuid is required"
    end

    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    local now_timestamp
    if db_type == sql.type.SQLITE then
        now_timestamp = sql.as.int(now_unix())
    else
        now_timestamp = now_utc()
    end

    local status = payload.status or consts.OPERATION_STATUS.PROCESSING

    local insert_query = sql.builder.insert("kb_embed_operations")
        :set_map({
            id = payload.id,
            component_id = payload.component_id,
            upload_uuid = payload.upload_uuid,
            status = status,
            error = payload.error or sql.as.null(),
            ops_executed = payload.ops_executed or 0,
            created_at = now_timestamp,
            updated_at = now_timestamp
        })

    local executor = insert_query:run_with(tx)
    local result, exec_err = executor:exec()

    if exec_err then
        return nil, "Failed to create embed operation: " .. exec_err
    end

    return {
        id = payload.id,
        component_id = payload.component_id,
        status = status,
        op_id = op_id
    }
end

handlers[consts.COMMAND_TYPES.UPDATE_EMBED_OPERATION_STATUS] = function(tx, kb_id, op_id, command)
    local payload = command.payload or {}

    if not payload.id or payload.id == "" then
        return nil, "Operation ID is required"
    end

    local db_type, err = get_db_type(tx)
    if err then
        return nil, err
    end

    local now_timestamp
    if db_type == sql.type.SQLITE then
        now_timestamp = sql.as.int(now_unix())
    else
        now_timestamp = now_utc()
    end

    local update_query = sql.builder.update("kb_embed_operations")
        :set("status", payload.status)
        :set("ops_executed", payload.ops_executed or 0)
        :set("updated_at", now_timestamp)
        :where("id = ?", payload.id)

    if payload.error then
        update_query = update_query:set("error", payload.error)
    end

    local executor = update_query:run_with(tx)
    local result, exec_err = executor:exec()

    if exec_err then
        return nil, "Failed to update embed operation: " .. exec_err
    end

    if result.rows_affected == 0 then
        return nil, "Operation not found"
    end

    return {
        id = payload.id,
        status = payload.status,
        op_id = op_id
    }
end

return {
    COMMAND_TYPES = consts.COMMAND_TYPES,
    ERROR = consts.ERROR,
    handlers = handlers
}