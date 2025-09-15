local sql = require("sql")
local uuid = require("uuid")
local consts = require("consts")
local ops = require("ops")

local DB_RESOURCE = "app:db"

---@class batch_builder
---@field component_id string
---@field operations table[]
---@field transaction any|nil
local batch_builder = {}
batch_builder.__index = batch_builder

---@class component_ops
---@field builder batch_builder
local component_ops = {}
component_ops.__index = component_ops

---@class node_ops
---@field builder batch_builder
---@field node_id string|nil
local node_ops = {}
node_ops.__index = node_ops

---@class edge_ops
---@field builder batch_builder
---@field edge_id string|nil
local edge_ops = {}
edge_ops.__index = edge_ops

---@return table|nil, string|nil
local function get_db()
    local db, err = sql.get(DB_RESOURCE)
    if err then
        return nil, "Failed to get database: " .. err
    end
    return db
end

---@param component_id string
---@return batch_builder
function batch_builder.new(component_id)
    if not component_id or component_id == "" then
        error("Component ID is required")
    end

    return setmetatable({
        component_id = component_id,
        operations = {},
        transaction = nil
    }, batch_builder)
end

---@param tx any
---@return batch_builder
function batch_builder:with_tx(tx)
    self.transaction = tx
    return self
end

---@param operations table[]
---@return batch_builder
function batch_builder:ops(operations)
    if not operations or type(operations) ~= "table" then
        error("Operations must be a table")
    end

    for _, operation in ipairs(operations) do
        if not operation.type or not operation.payload then
            error("Each operation must have type and payload")
        end
        table.insert(self.operations, operation)
    end

    return self
end

---@return component_ops
function batch_builder:component()
    return component_ops.new(self)
end

---@param node_id string|nil
---@return node_ops
function batch_builder:node(node_id)
    return node_ops.new(self, node_id)
end

---@param edge_id string|nil
---@return edge_ops
function batch_builder:edge(edge_id)
    return edge_ops.new(self, edge_id)
end

---Purge all data for this component (nodes, edges, embeddings, component)
---@return batch_builder
function batch_builder:purge()
    -- Add a special PURGE_COMPLETE operation that will be handled by the execute method
    table.insert(self.operations, {
        type = "PURGE_COMPLETE",
        payload = {
            component_id = self.component_id,
            message = "All KB data purged successfully"
        }
    })

    return self
end

---@return table|nil, string|nil
function batch_builder:execute()
    if #self.operations == 0 then
        return { success = true, results = {} }
    end

    local db, err
    local tx = self.transaction
    local should_commit = false

    if not tx then
        db, err = get_db()
        if err then
            return nil, err
        end

        tx, err = db:begin()
        if err then
            if db then db:release() end
            return nil, "Failed to begin transaction: " .. err
        end
        should_commit = true
    end

    local results = {}
    local op_id = uuid.v7()

    for i, operation in ipairs(self.operations) do
        -- Handle PURGE_COMPLETE specially - actually purge the component
        if operation.type == "PURGE_COMPLETE" then
            local db_type, type_err = tx:db_type()
            if type_err then
                if should_commit then
                    tx:rollback()
                    if db then db:release() end
                end
                return nil, "Failed to get database type: " .. type_err
            end

            local nodes_deleted = 0

            if db_type == sql.type.SQLITE then
                -- SQLite: Manual cleanup of virtual tables before cascade delete

                -- Step 1: Get all node IDs for this component (for FTS cleanup)
                local node_ids_query = sql.builder.select("n.id")
                    :from("kb_nodes n")
                    :join("kb_components c ON n.kb_id = c.id")
                    :where("c.component_id = ?", self.component_id)

                local node_executor = node_ids_query:run_with(tx)
                local node_results, node_err = node_executor:query()
                if node_err then
                    if should_commit then
                        tx:rollback()
                        if db then db:release() end
                    end
                    return nil, "Failed to get nodes for cleanup: " .. node_err
                end

                -- Step 2: Clean up FTS entries manually
                for _, node_row in ipairs(node_results) do
                    local fts_delete_sql = "DELETE FROM kb_nodes_fts WHERE node_id = ?"
                    local _, fts_err = tx:execute(fts_delete_sql, {node_row.id})
                    -- Continue even if FTS delete fails (non-critical)
                end

                -- Step 3: Clean up embeddings manually (vec0 virtual table)
                local embedding_delete_sql = "DELETE FROM kb_node_embeddings WHERE kb_id IN (SELECT id FROM kb_components WHERE component_id = ?)"
                local _, embed_err = tx:execute(embedding_delete_sql, {self.component_id})
                if embed_err then
                    if should_commit then
                        tx:rollback()
                        if db then db:release() end
                    end
                    return nil, "Failed to delete embeddings: " .. embed_err
                end

                -- Step 4: Count nodes before deletion
                local count_query = sql.builder.select("COUNT(*) as count")
                    :from("kb_nodes n")
                    :join("kb_components c ON n.kb_id = c.id")
                    :where("c.component_id = ?", self.component_id)

                local count_executor = count_query:run_with(tx)
                local count_results, count_err = count_executor:query()
                if not count_err and count_results and #count_results > 0 then
                    nodes_deleted = count_results[1].count or 0
                end

                -- Step 5: Delete the component (CASCADE handles nodes)
                local delete_component_query = sql.builder.delete("kb_components")
                    :where("component_id = ?", self.component_id)

                local component_executor = delete_component_query:run_with(tx)
                local component_result, component_err = component_executor:exec()
                if component_err then
                    if should_commit then
                        tx:rollback()
                        if db then db:release() end
                    end
                    return nil, "Failed to delete component: " .. component_err
                end

            else
                -- PostgreSQL: Rely on CASCADE constraints, but count first
                local count_query = sql.builder.select("COUNT(*) as count")
                    :from("kb_nodes n")
                    :join("kb_components c ON n.kb_id = c.id")
                    :where("c.component_id = ?", self.component_id)

                local count_executor = count_query:run_with(tx)
                local count_results, count_err = count_executor:query()
                if not count_err and count_results and #count_results > 0 then
                    nodes_deleted = count_results[1].count or 0
                end

                -- Delete the component (CASCADE handles everything)
                local delete_component_query = sql.builder.delete("kb_components")
                    :where("component_id = ?", self.component_id)

                local component_executor = delete_component_query:run_with(tx)
                local component_result, component_err = component_executor:exec()
                if component_err then
                    if should_commit then
                        tx:rollback()
                        if db then db:release() end
                    end
                    return nil, "Failed to delete component: " .. component_err
                end
            end

            -- Add result for PURGE_COMPLETE
            table.insert(results, {
                component_id = self.component_id,
                nodes_deleted = nodes_deleted,
                purged = true,
                message = operation.payload.message
            })

            goto continue
        end

        -- Handle regular operations through ops handlers
        local handler = ops.handlers[operation.type]
        if not handler then
            if should_commit then
                tx:rollback()
                if db then db:release() end
            end
            return nil, "Unknown operation type: " .. operation.type
        end

        local result, err = handler(tx, self.component_id, op_id, operation)
        if err then
            if should_commit then
                tx:rollback()
                if db then db:release() end
            end
            return nil, "Operation " .. i .. " failed: " .. err
        end

        table.insert(results, result)

        ::continue::
    end

    if should_commit then
        local ok, err = tx:commit()
        if not ok then
            tx:rollback()
            if db then db:release() end
            return nil, "Failed to commit transaction: " .. err
        end
        if db then db:release() end
    end

    return { success = true, results = results }
end

---@param builder batch_builder
---@return component_ops
function component_ops.new(builder)
    return setmetatable({
        builder = builder
    }, component_ops)
end

---@param config table
---@return batch_builder
function component_ops:create(config)
    if not config or type(config) ~= "table" then
        error("Config is required for component creation")
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.CREATE_COMPONENT,
        payload = {
            id = self.builder.component_id,
            component_id = self.builder.component_id,
            config = config
        }
    })

    return self.builder
end

---@param config table
---@return batch_builder
function component_ops:update(config)
    if not config or type(config) ~= "table" then
        error("Config is required for component update")
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.UPDATE_COMPONENT,
        payload = {
            id = self.builder.component_id,
            config = config
        }
    })

    return self.builder
end

---@return batch_builder
function component_ops:delete()
    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.DELETE_COMPONENT,
        payload = {
            id = self.builder.component_id
        }
    })

    return self.builder
end

---@param builder batch_builder
---@param node_id string|nil
---@return node_ops
function node_ops.new(builder, node_id)
    return setmetatable({
        builder = builder,
        node_id = node_id
    }, node_ops)
end

---@param node_data table
---@return batch_builder
function node_ops:create(node_data)
    if not node_data or type(node_data) ~= "table" then
        error("Node data is required")
    end

    local payload = {}
    for k, v in pairs(node_data) do
        payload[k] = v
    end

    if self.node_id then
        payload.id = self.node_id
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.CREATE_NODE,
        payload = payload
    })

    return self.builder
end

---@param node_data table
---@return batch_builder
function node_ops:update(node_data)
    if not self.node_id then
        error("Node ID is required for update")
    end

    if not node_data or type(node_data) ~= "table" then
        error("Node data is required")
    end

    local payload = { id = self.node_id }
    for k, v in pairs(node_data) do
        payload[k] = v
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.UPDATE_NODE,
        payload = payload
    })

    return self.builder
end

---@return batch_builder
function node_ops:delete()
    if not self.node_id then
        error("Node ID is required for delete")
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.DELETE_NODE,
        payload = {
            id = self.node_id
        }
    })

    return self.builder
end

---@param node_ids string[]
---@return batch_builder
function node_ops:delete_many(node_ids)
    if not node_ids or type(node_ids) ~= "table" or #node_ids == 0 then
        error("Node IDs array is required")
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.DELETE_NODES,
        payload = {
            ids = node_ids
        }
    })

    return self.builder
end

---@param edge_data table
---@return batch_builder
function node_ops:move(edge_data)
    if not self.node_id then
        error("Node ID is required for move")
    end

    if not edge_data or type(edge_data) ~= "table" then
        error("Move data is required")
    end

    local payload = { id = self.node_id }
    for k, v in pairs(edge_data) do
        payload[k] = v
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.MOVE_NODE,
        payload = payload
    })

    return self.builder
end

---@param builder batch_builder
---@param edge_id string|nil
---@return edge_ops
function edge_ops.new(builder, edge_id)
    return setmetatable({
        builder = builder,
        edge_id = edge_id
    }, edge_ops)
end

---@param edge_data table
---@return batch_builder
function edge_ops:create(edge_data)
    if not edge_data or type(edge_data) ~= "table" then
        error("Edge data is required")
    end

    local payload = {}
    for k, v in pairs(edge_data) do
        payload[k] = v
    end

    if self.edge_id then
        payload.id = self.edge_id
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.CREATE_EDGE,
        payload = payload
    })

    return self.builder
end

---@param edge_data table
---@return batch_builder
function edge_ops:update(edge_data)
    if not self.edge_id then
        error("Edge ID is required for update")
    end

    if not edge_data or type(edge_data) ~= "table" then
        error("Edge data is required")
    end

    local payload = { id = self.edge_id }
    for k, v in pairs(edge_data) do
        payload[k] = v
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.UPDATE_EDGE,
        payload = payload
    })

    return self.builder
end

---@return batch_builder
function edge_ops:delete()
    if not self.edge_id then
        error("Edge ID is required for delete")
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.DELETE_EDGE,
        payload = {
            id = self.edge_id
        }
    })

    return self.builder
end

---@param edge_ids string[]
---@return batch_builder
function edge_ops:delete_many(edge_ids)
    if not edge_ids or type(edge_ids) ~= "table" or #edge_ids == 0 then
        error("Edge IDs array is required")
    end

    table.insert(self.builder.operations, {
        type = consts.COMMAND_TYPES.DELETE_EDGES,
        payload = {
            ids = edge_ids
        }
    })

    return self.builder
end

---@param component_id string
---@return table|nil, string|nil
local function get_component(component_id)
    if not component_id or component_id == "" then
        return nil, "Component ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("*")
        :from("kb_components")
        :where("component_id = ?", component_id)

    local executor = query:run_with(db)
    local results, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to get component: " .. err
    end

    if #results == 0 then
        return nil, "Component not found"
    end

    return results[1]
end

---@param component_id string
---@return batch_builder
local function new_batch(component_id)
    return batch_builder.new(component_id)
end

local store = {
    new_batch = new_batch,
    get_component = get_component
}

-- Make store callable as shorthand for new_batch
setmetatable(store, {
    __call = function(_, component_id)
        return batch_builder.new(component_id)
    end
})

return store