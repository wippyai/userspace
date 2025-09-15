local ctx = require("ctx")
local json = require("json")
local sql = require("sql")

local function handle(request_dto)
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            success = false,
            error = { code = "NO_CONTEXT", message = "No component context: " .. err }
        }
    end

    local req = request_dto or {}

    -- Extract parameters (nil values are fine)
    local path = req.path
    local exact_path = req.exact_path
    local node_types = req.node_types
    local node_id = req.node_id
    local node_ids = req.node_ids
    local parent_id = req.parent_id
    local search_query = req.search_query
    local include_content = req.include_content or false
    local include_metadata = req.include_metadata ~= false       -- default true
    local with_children_count = req.with_children_count ~= false -- default true
    local limit = req.limit or 50
    local offset = req.offset or 0
    local order_by = req.order_by or "path"

    -- Validate limit bounds
    if limit < 1 or limit > 500 then
        return {
            success = false,
            error = { code = "INVALID_LIMIT", message = "Limit must be between 1 and 500" }
        }
    end

    -- Validate offset
    if offset < 0 then
        return {
            success = false,
            error = { code = "INVALID_OFFSET", message = "Offset must be non-negative" }
        }
    end

    -- Get database connection
    local db, db_err = sql.get("app:db")
    if db_err then
        return {
            success = false,
            error = { code = "DB_ERROR", message = "Failed to get database: " .. db_err }
        }
    end

    -- Get internal KB ID from component_id
    local kb_comp_query = sql.builder.select("id")
        :from("kb_components")
        :where("component_id = ?", component_id)

    local kb_comp_exec = kb_comp_query:run_with(db)
    local kb_comp_result, kb_comp_err = kb_comp_exec:query()

    if kb_comp_err then
        db:release()
        return {
            success = false,
            error = { code = "KB_LOOKUP_FAILED", message = "Failed to lookup KB: " .. kb_comp_err }
        }
    end

    if #kb_comp_result == 0 then
        db:release()
        return {
            success = false,
            error = { code = "KB_NOT_FOUND", message = "Knowledge base not found for component: " .. component_id }
        }
    end

    local kb_id = kb_comp_result[1].id

    -- Build base SELECT fields
    local select_fields = { "n.id", "n.parent_id", "n.path", "n.node_type",
        "n.value", "n.content_type", "n.created_at", "n.updated_at" }

    if include_content then
        table.insert(select_fields, "n.content")
    end

    if include_metadata then
        table.insert(select_fields, "n.metadata")
    end

    -- Add children count subquery if requested
    if with_children_count then
        table.insert(select_fields,
            "(SELECT COUNT(*) FROM kb_nodes c WHERE c.parent_id = n.id AND c.kb_id = n.kb_id) AS children_count")
    end

    -- Build main query
    local query = sql.builder.select(unpack(select_fields))
        :from("kb_nodes n")
        :where("n.kb_id = ?", kb_id)

    -- Apply filters based on provided parameters

    -- 1. Single node ID lookup
    if node_id and node_id ~= "" then
        query = query:where("n.id = ?", node_id)

        -- 2. Multiple node IDs lookup
    elseif node_ids and type(node_ids) == "table" and #node_ids > 0 then
        local placeholders = {}
        for i = 1, #node_ids do
            table.insert(placeholders, "?")
        end
        query = query:where(
            sql.builder.expr("n.id IN (" .. table.concat(placeholders, ", ") .. ")",
                unpack(node_ids))
        )

        -- 3. Parent ID filter (direct children)
    elseif parent_id and parent_id ~= "" then
        query = query:where("n.parent_id = ?", parent_id)

        -- 4. Exact path match
    elseif exact_path and exact_path ~= "" then
        query = query:where("n.path = ?", exact_path)

        -- 5. Path prefix filter (children under path)
    elseif path and path ~= "" then
        query = query:where("n.path LIKE ?", path .. ".%")

        -- 6. Node type filtering (show all nodes of these types)
    elseif node_types and type(node_types) == "table" and #node_types > 0 then
        if #node_types == 1 then
            query = query:where("n.node_type = ?", node_types[1])
        else
            local type_placeholders = {}
            for i = 1, #node_types do
                table.insert(type_placeholders, "?")
            end
            query = query:where(
                sql.builder.expr("n.node_type IN (" .. table.concat(type_placeholders, ", ") .. ")",
                    unpack(node_types))
            )
        end
    else
        -- 7. Default: root nodes if no other filters
        query = query:where("n.parent_id IS NULL")
    end

    -- Apply search query filter
    if search_query and search_query ~= "" then
        -- Get database type to determine search method
        local db_type, type_err = db:type()
        if not type_err then
            if db_type == sql.type.POSTGRES then
                query = query:where("n.search_vector @@ to_tsquery('english', ?)", search_query)
            elseif db_type == sql.type.SQLITE then
                query = query:where(sql.builder.expr(
                    "n.id IN (SELECT node_id FROM kb_nodes_fts WHERE kb_nodes_fts MATCH ?)",
                    search_query
                ))
            end
        end
    end

    -- Apply ordering BEFORE pagination
    if order_by == "created_at" then
        query = query:order_by("n.created_at ASC")
    elseif order_by == "updated_at" then
        query = query:order_by("n.updated_at DESC")
    elseif order_by == "node_type" then
        query = query:order_by("n.node_type ASC", "n.path ASC")
    else -- default to path
        query = query:order_by("n.path ASC")
    end

    -- Apply pagination
    query = query:limit(limit):offset(offset)

    -- Execute main query
    local executor = query:run_with(db)
    local results, query_err = executor:query()
    if query_err then
        db:release()
        return {
            success = false,
            error = { code = "QUERY_FAILED", message = "Failed to query nodes: " .. query_err }
        }
    end

    -- Build count query for pagination (same filters, no limit/offset)
    local count_query = sql.builder.select("COUNT(*) as total")
        :from("kb_nodes n")
        :where("n.kb_id = ?", kb_id)

    -- Apply same filters to count query (FIXED - matches main query logic exactly)
    if node_id and node_id ~= "" then
        count_query = count_query:where("n.id = ?", node_id)
    elseif node_ids and type(node_ids) == "table" and #node_ids > 0 then
        local placeholders = {}
        for i = 1, #node_ids do
            table.insert(placeholders, "?")
        end
        count_query = count_query:where(
            sql.builder.expr("n.id IN (" .. table.concat(placeholders, ", ") .. ")",
                unpack(node_ids))
        )
    elseif parent_id and parent_id ~= "" then
        count_query = count_query:where("n.parent_id = ?", parent_id)
    elseif exact_path and exact_path ~= "" then
        count_query = count_query:where("n.path = ?", exact_path)
    elseif path and path ~= "" then
        count_query = count_query:where("n.path LIKE ?", path .. ".%")
    elseif node_types and type(node_types) == "table" and #node_types > 0 then
        if #node_types == 1 then
            count_query = count_query:where("n.node_type = ?", node_types[1])
        else
            local type_placeholders = {}
            for i = 1, #node_types do
                table.insert(type_placeholders, "?")
            end
            count_query = count_query:where(
                sql.builder.expr("n.node_type IN (" .. table.concat(type_placeholders, ", ") .. ")",
                    unpack(node_types))
            )
        end
    else
        count_query = count_query:where("n.parent_id IS NULL")
    end

    -- Apply search filter to count query
    if search_query and search_query ~= "" then
        local db_type, type_err = db:type()
        if not type_err then
            if db_type == sql.type.POSTGRES then
                count_query = count_query:where("n.search_vector @@ to_tsquery('english', ?)", search_query)
            elseif db_type == sql.type.SQLITE then
                count_query = count_query:where(sql.builder.expr(
                    "n.id IN (SELECT node_id FROM kb_nodes_fts WHERE kb_nodes_fts MATCH ?)",
                    search_query
                ))
            end
        end
    end

    -- Execute count query
    local count_executor = count_query:run_with(db)
    local count_result, count_err = count_executor:query()
    if count_err then
        db:release()
        return {
            success = false,
            error = { code = "COUNT_FAILED", message = "Failed to count nodes: " .. count_err }
        }
    end

    local total_count = count_result[1].total or 0

    -- Release database
    db:release()

    -- Parse metadata for results
    local function parse_metadata(metadata_str)
        if not metadata_str or metadata_str == "" then
            return {}
        end
        local success, parsed = pcall(json.decode, metadata_str)
        return success and parsed or {}
    end

    -- Build response nodes
    local nodes = {}
    for _, row in ipairs(results) do
        local node = {
            id = row.id,
            parent_id = row.parent_id,
            path = row.path or "",
            node_type = row.node_type or "unknown",
            value = row.value,
            content_type = row.content_type,
            created_at = row.created_at,
            updated_at = row.updated_at
        }

        -- Add content if requested
        if include_content and row.content then
            node.content = row.content
            node.content_length = string.len(row.content)
        else
            node.content_length = row.content and string.len(row.content) or 0
        end

        -- Add metadata if requested and available
        if include_metadata and row.metadata then
            node.metadata = parse_metadata(row.metadata)
        end

        -- Add children info
        if with_children_count then
            node.children_count = row.children_count or 0
            node.has_children = node.children_count > 0
        else
            node.has_children = false -- Conservative default when not calculated
        end

        table.insert(nodes, node)
    end

    -- Build pagination info
    local pagination = {
        total = total_count,
        limit = limit,
        offset = offset,
        has_more = (offset + limit) < total_count
    }

    return {
        success = true,
        nodes = nodes,
        pagination = pagination
    }
end

return { handle = handle }