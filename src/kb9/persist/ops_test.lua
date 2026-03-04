local test = require("test")
local sql = require("sql")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local ops = require("ops")
local consts = require("consts")

local function run_tests()
    describe("KB9 Operations", function()
        local test_ctx = {
            kb_id = nil,
            created_components = {},
            created_nodes = {},
            created_embeddings = {}
        }

        local function execute_op_with_commit(op_type, payload)
            local db, err = sql.get("app:db")
            if err then return nil, "Failed to get database: " .. err end

            local tx, err = db:begin()
            if err then
                db:release()
                return nil, "Failed to begin transaction: " .. err
            end

            local command = {
                type = op_type,
                payload = payload
            }

            local result, err = ops.handlers[op_type](tx, test_ctx.kb_id, uuid.v7(), command)
            if err then
                tx:rollback()
                db:release()
                return nil, "Operation failed: " .. err
            end

            local ok, err = tx:commit()
            if err then
                db:release()
                return nil, "Failed to commit: " .. err
            end

            db:release()
            return result, nil
        end

        local function get_db_type()
            local db, err = sql.get("app:db")
            if err then error("Failed to get database: " .. err) end

            local db_type, err = db:type()
            db:release()
            if err then error("Failed to get database type: " .. err) end

            return db_type
        end

        local function generate_test_embedding()
            local embedding = {}
            math.randomseed(os.time())
            for i = 1, 512 do
                embedding[i] = (math.random() - 0.5) * 2
            end
            return embedding
        end

        local function verify_embedding_fields_sqlite(node_id, expected_fields)
            local db_type = get_db_type()
            if db_type ~= sql.type.SQLITE then
                return true
            end

            local db, err = sql.get("app:db")
            if err then error("Failed to get database: " .. err) end

            local check_sql = [[
                SELECT node_type, parent_id, path, content_type
                FROM kb_node_embeddings
                WHERE node_id = ? AND kb_id = ?
            ]]

            local embeddings, err = db:query(check_sql, {node_id, test_ctx.kb_id})
            db:release()

            if err then
                error("Failed to check embedding fields: " .. err)
            end

            if #embeddings == 0 then
                return false
            end

            local embedding = embeddings[1]

            local function safe_compare(actual, expected)
                if expected == nil then
                    return actual == "" or actual == nil
                end
                return actual == expected
            end

            local node_type_match = safe_compare(embedding.node_type, expected_fields.node_type)
            local parent_id_match = safe_compare(embedding.parent_id, expected_fields.parent_id)
            local path_match = safe_compare(embedding.path, expected_fields.path)
            local content_type_match = safe_compare(embedding.content_type, expected_fields.content_type)

            return node_type_match and parent_id_match and path_match and content_type_match
        end

        local function verify_embeddings_deleted_sqlite(node_ids, kb_id)
            local db_type = get_db_type()
            if db_type ~= sql.type.SQLITE then
                return true
            end

            local db, err = sql.get("app:db")
            if err then
                error("Failed to get database: " .. err)
            end

            local placeholders = {}
            for i = 1, #node_ids do
                placeholders[i] = "?"
            end

            local check_sql = string.format([[
                SELECT COUNT(*) as count
                FROM kb_node_embeddings
                WHERE node_id IN (%s) AND kb_id = ?
            ]], table.concat(placeholders, ","))

            local params = {}
            for i, node_id in ipairs(node_ids) do
                params[i] = node_id
            end
            table.insert(params, kb_id)

            local results, err = db:query(check_sql, params)
            db:release()

            if err then
                error("Failed to check embeddings: " .. err)
            end

            local embedding_count = results[1] and results[1].count or 0
            return embedding_count == 0
        end

        local function verify_embedding_exists_sqlite(node_id, kb_id, model_name)
            local db_type = get_db_type()
            if db_type ~= sql.type.SQLITE then
                return true
            end

            local db, err = sql.get("app:db")
            if err then
                error("Failed to get database: " .. err)
            end

            local check_sql = [[
                SELECT COUNT(*) as count
                FROM kb_node_embeddings
                WHERE node_id = ? AND kb_id = ? AND model_name = ?
            ]]

            local results, err = db:query(check_sql, {node_id, kb_id, model_name})
            db:release()

            if err then
                error("Failed to check embedding existence: " .. err)
            end

            local embedding_count = results[1] and results[1].count or 0
            return embedding_count > 0
        end

        local function cleanup_test_data()
            local db, err = sql.get("app:db")
            if err then
                print("Warning: Could not connect to database for cleanup: " .. err)
                return
            end

            if #test_ctx.created_embeddings > 0 then
                local delete_embeddings = sql.builder.delete("kb_node_embeddings")
                    :where("kb_id = ?", test_ctx.kb_id)

                local executor = delete_embeddings:run_with(db)
                local _, err = executor:exec()
                if err then
                    print("Warning: Could not clean up embeddings: " .. err)
                end
            end

            -- Clean up embed operations
            if #test_ctx.created_operations > 0 then
                for _, op_id in ipairs(test_ctx.created_operations) do
                    local delete_op = sql.builder.delete("kb_embed_operations")
                        :where("id = ?", op_id)
                    local executor = delete_op:run_with(db)
                    executor:exec()
                end
            end

            db:release()

            if #test_ctx.created_nodes > 0 then
                execute_op_with_commit(ops.COMMAND_TYPES.DELETE_NODES, {
                    ids = test_ctx.created_nodes
                })
            end

            if #test_ctx.created_components > 0 then
                for _, component_id in ipairs(test_ctx.created_components) do
                    execute_op_with_commit(ops.COMMAND_TYPES.DELETE_COMPONENT, {
                        id = component_id
                    })
                end
            end
        end

        before_each(function()
            test_ctx.kb_id = uuid.v7()
            test_ctx.created_components = {}
            test_ctx.created_nodes = {}
            test_ctx.created_embeddings = {}
            test_ctx.created_operations = {}

            local component_result = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_COMPONENT, {
                id = test_ctx.kb_id,
                component_id = test_ctx.kb_id,
                config = {test = true}
            })
            table.insert(test_ctx.created_components, test_ctx.kb_id)
        end)

        after_each(function()
            cleanup_test_data()
        end)

        describe("Component Operations", function()
            it("should create component successfully", function()
                local new_component_id = uuid.v7()
                local config = {
                    name = "Test Component",
                    version = "1.0",
                    settings = {
                        auto_process = true,
                        max_chunks = 100
                    }
                }

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_COMPONENT, {
                    id = new_component_id,
                    component_id = new_component_id,
                    config = config
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(new_component_id)
                expect(result.component_id).to_equal(new_component_id)
                table.insert(test_ctx.created_components, new_component_id)
            end)

            it("should update component successfully", function()
                local updated_config = {
                    name = "Updated Test Component",
                    version = "2.0",
                    settings = {
                        auto_process = false,
                        max_chunks = 200
                    }
                }

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_COMPONENT, {
                    id = test_ctx.kb_id,
                    config = updated_config
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(test_ctx.kb_id)
            end)

            it("should delete component successfully", function()
                local temp_component_id = uuid.v7()

                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_COMPONENT, {
                    id = temp_component_id,
                    component_id = temp_component_id,
                    config = {temp = true}
                })
                expect(err).to_be_nil()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_COMPONENT, {
                    id = temp_component_id
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(temp_component_id)
                expect(result.deleted).to_be_true()
            end)

            it("should create component with default config when none provided", function()
                local component_id = uuid.v7()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_COMPONENT, {
                    id = component_id,
                    component_id = component_id
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(component_id)
                expect(result.component_id).to_equal(component_id)
                table.insert(test_ctx.created_components, component_id)
            end)

            it("should error when updating non-existent component", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_COMPONENT, {
                    id = uuid.v7(),
                    config = {test = true}
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)
        end)

        describe("Node Operations", function()
            it("should create root node successfully", function()
                local node_id = uuid.v7()
                local metadata = {
                    category = "test",
                    importance = "high",
                    tags = {"example", "root"}
                }

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id,
                    node_type = "document",
                    content = "This is a test document content",
                    content_type = "text/plain",
                    value = "test_value",
                    metadata = metadata
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(node_id)
                expect(result.path).not_to_be_nil()
                table.insert(test_ctx.created_nodes, node_id)
            end)

            it("should create child node successfully", function()
                local parent_id = uuid.v7()
                local parent_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = parent_id,
                    node_type = "folder",
                    content = "Parent folder"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, parent_id)

                local child_id = uuid.v7()
                local child_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = child_id,
                    parent_id = parent_id,
                    node_type = "document",
                    content = "Child document"
                })

                expect(err).to_be_nil()
                expect(child_result.id).to_equal(child_id)
                expect(child_result.path).to_contain(parent_result.path)
                table.insert(test_ctx.created_nodes, child_id)
            end)

            it("should update node successfully", function()
                local node_id = uuid.v7()
                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id,
                    node_type = "document",
                    content = "Original content"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, node_id)

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_NODE, {
                    id = node_id,
                    content = "Updated content",
                    node_type = "article",
                    metadata = {updated = true}
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(node_id)
                expect(result.changed).to_be_true()
            end)

            it("should delete single node successfully", function()
                local node_id = uuid.v7()
                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id,
                    node_type = "document",
                    content = "To be deleted"
                })
                expect(err).to_be_nil()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_NODE, {
                    id = node_id
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(node_id)
                expect(result.deleted).to_be_true()
                expect(result.nodes_deleted).to_be_greater_than(0)
            end)

            it("should delete multiple nodes successfully", function()
                local node_ids = {}
                for i = 1, 3 do
                    local node_id = uuid.v7()
                    local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                        id = node_id,
                        node_type = "document",
                        content = "Document " .. i
                    })
                    expect(err).to_be_nil()
                    table.insert(node_ids, node_id)
                end

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_NODES, {
                    ids = node_ids
                })

                expect(err).to_be_nil()
                expect(#result.ids).to_equal(3)
                expect(result.total_deleted).to_be_greater_than(0)
            end)

            it("should delete node hierarchy successfully", function()
                local parent_id = uuid.v7()
                local parent_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = parent_id,
                    node_type = "folder",
                    content = "Parent folder"
                })
                expect(err).to_be_nil()

                local child_ids = {}
                for i = 1, 2 do
                    local child_id = uuid.v7()
                    local child_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                        id = child_id,
                        parent_id = parent_id,
                        node_type = "document",
                        content = "Child " .. i
                    })
                    expect(err).to_be_nil()
                    table.insert(child_ids, child_id)
                end

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_NODE, {
                    id = parent_id
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(parent_id)
                expect(result.deleted).to_be_true()
                expect(result.nodes_deleted).to_equal(3)
            end)

            it("should error when creating node without required fields", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = uuid.v7()
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should error when updating non-existent node", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_NODE, {
                    id = uuid.v7(),
                    content = "Updated content"
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should handle update with no changes", function()
                local node_id = uuid.v7()
                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id,
                    node_type = "document",
                    content = "Original content"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, node_id)

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_NODE, {
                    id = node_id
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(node_id)
                expect(result.changed).to_be_false()
            end)
        end)

        describe("Embedding Operations", function()
            local test_node_id

            before_each(function()
                test_node_id = uuid.v7()
                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = test_node_id,
                    node_type = "document",
                    content = "Test document for embeddings",
                    content_type = "text/markdown",
                    metadata = {test = true}
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, test_node_id)
            end)

            it("should create embedding successfully", function()
                local embedding_vector = generate_test_embedding()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })

                expect(err).to_be_nil()
                expect(result.node_id).to_equal(test_node_id)
                expect(result.created).to_be_true()
                expect(result.id).not_to_be_nil()
                table.insert(test_ctx.created_embeddings, result.id)
            end)

            it("should update existing embedding successfully", function()
                local embedding_vector = generate_test_embedding()

                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_embeddings, create_result.id)

                local new_embedding_vector = generate_test_embedding()
                local update_result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = new_embedding_vector,
                    model_name = "test_model"
                })

                expect(err).to_be_nil()
                expect(update_result.node_id).to_equal(test_node_id)
                expect(update_result.updated).to_be_true()
                expect(update_result.id).to_equal(create_result.id)
            end)

            it("should verify embedding field sync in SQLite", function()
                local db_type = get_db_type()
                if db_type ~= sql.type.SQLITE then
                    return
                end

                local db, err = sql.get("app:db")
                if err then error("Failed to get database: " .. err) end

                local node_query = sql.builder.select("path")
                    :from("kb_nodes")
                    :where("id = ?", test_node_id)
                    :where("kb_id = ?", test_ctx.kb_id)

                local executor = node_query:run_with(db)
                local node_results, err = executor:query()
                db:release()

                if err then error("Failed to get node path: " .. err) end
                if #node_results == 0 then error("Test node not found") end

                local node_path = node_results[1].path

                local embedding_vector = generate_test_embedding()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })
                expect(err).to_be_nil()

                local synced = verify_embedding_fields_sqlite(test_node_id, {
                    node_type = "document",
                    parent_id = nil,
                    path = node_path,
                    content_type = "text/markdown"
                })

                expect(synced).to_be_true()
                table.insert(test_ctx.created_embeddings, result.id)
            end)

            it("should handle NULL values correctly in SQLite embeddings", function()
                local db_type = get_db_type()
                if db_type ~= sql.type.SQLITE then
                    return
                end

                local root_node_id = uuid.v7()
                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = root_node_id,
                    node_type = "root",
                    content = "Root node content"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, root_node_id)

                local embedding_vector = generate_test_embedding()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = root_node_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })

                expect(err).to_be_nil()
                expect(result.node_id).to_equal(root_node_id)
                expect(result.created).to_be_true()
                table.insert(test_ctx.created_embeddings, result.id)
            end)

            it("should delete embedding successfully", function()
                local embedding_vector = generate_test_embedding()

                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })
                expect(err).to_be_nil()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_EMBEDDING, {
                    node_id = test_node_id,
                    model_name = "test_model"
                })

                expect(err).to_be_nil()
                expect(result.node_id).to_equal(test_node_id)
                expect(result.deleted).to_be_true()
            end)

            it("should delete all embeddings for node when no model specified", function()
                local embedding_vector = generate_test_embedding()

                local result1, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = embedding_vector,
                    model_name = "model_1"
                })
                expect(err).to_be_nil()

                local result2, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = embedding_vector,
                    model_name = "model_2"
                })
                expect(err).to_be_nil()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_EMBEDDING, {
                    node_id = test_node_id
                })

                expect(err).to_be_nil()
                expect(result.node_id).to_equal(test_node_id)
                expect(result.deleted).to_be_true()
            end)

            it("should actually delete embeddings when node is deleted (SQLite verification)", function()
                local db_type = get_db_type()
                if db_type ~= sql.type.SQLITE then
                    return
                end

                local parent_id = uuid.v7()
                local parent_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = parent_id,
                    node_type = "folder",
                    content = "Parent folder"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, parent_id)

                local child_id = uuid.v7()
                local child_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = child_id,
                    parent_id = parent_id,
                    node_type = "document",
                    content = "Child document"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, child_id)

                local embedding_vector = generate_test_embedding()

                local parent_embedding, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = parent_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })
                expect(err).to_be_nil()

                local child_embedding, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = child_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })
                expect(err).to_be_nil()

                expect(verify_embedding_exists_sqlite(parent_id, test_ctx.kb_id, "test_model")).to_be_true()
                expect(verify_embedding_exists_sqlite(child_id, test_ctx.kb_id, "test_model")).to_be_true()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_NODE, {
                    id = parent_id
                })

                expect(err).to_be_nil()
                expect(result.deleted).to_be_true()
                expect(result.nodes_deleted).to_equal(2)

                expect(verify_embeddings_deleted_sqlite({parent_id, child_id}, test_ctx.kb_id)).to_be_true()
            end)

            it("should delete all embeddings when multiple nodes are deleted (SQLite verification)", function()
                local db_type = get_db_type()
                if db_type ~= sql.type.SQLITE then
                    return
                end

                local node_ids = {}
                local embedding_vector = generate_test_embedding()

                for i = 1, 3 do
                    local node_id = uuid.v7()
                    local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                        id = node_id,
                        node_type = "document",
                        content = "Document " .. i
                    })
                    expect(err).to_be_nil()
                    table.insert(node_ids, node_id)
                    table.insert(test_ctx.created_nodes, node_id)

                    local embed_result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                        node_id = node_id,
                        embedding = embedding_vector,
                        model_name = "test_model"
                    })
                    expect(err).to_be_nil()

                    expect(verify_embedding_exists_sqlite(node_id, test_ctx.kb_id, "test_model")).to_be_true()
                end

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_NODES, {
                    ids = node_ids
                })

                expect(err).to_be_nil()
                expect(#result.ids).to_equal(3)
                expect(result.total_deleted).to_equal(3)

                expect(verify_embeddings_deleted_sqlite(node_ids, test_ctx.kb_id)).to_be_true()
            end)

            it("should error with invalid embedding dimensions", function()
                local invalid_embedding = {1, 2, 3}

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = invalid_embedding,
                    model_name = "test_model"
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should error with non-table embedding", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = test_node_id,
                    embedding = "not_a_vector",
                    model_name = "test_model"
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should error when creating embedding for non-existent node", function()
                local embedding_vector = generate_test_embedding()
                local non_existent_node_id = uuid.v7()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = non_existent_node_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)
        end)

        describe("Complex Scenarios", function()
            it("should handle cascading deletes with embeddings", function()
                local parent_id = uuid.v7()
                local parent_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = parent_id,
                    node_type = "folder",
                    content = "Parent folder"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, parent_id)

                local child_id = uuid.v7()
                local child_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = child_id,
                    parent_id = parent_id,
                    node_type = "document",
                    content = "Child document"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, child_id)

                local embedding_vector = generate_test_embedding()
                local embedding_result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                    node_id = child_id,
                    embedding = embedding_vector,
                    model_name = "test_model"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_embeddings, embedding_result.id)

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_NODE, {
                    id = parent_id
                })

                expect(err).to_be_nil()
                expect(result.deleted).to_be_true()
                expect(result.nodes_deleted).to_equal(2)
            end)

            it("should handle batch node creation and embedding", function()
                local node_ids = {}
                local embedding_vector = generate_test_embedding()

                for i = 1, 3 do
                    local node_id = uuid.v7()
                    local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                        id = node_id,
                        node_type = "document",
                        content = "Document " .. i
                    })
                    expect(err).to_be_nil()
                    table.insert(node_ids, node_id)
                    table.insert(test_ctx.created_nodes, node_id)

                    local embedding_result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPSERT_EMBEDDING, {
                        node_id = node_id,
                        embedding = embedding_vector,
                        model_name = "test_model"
                    })
                    expect(err).to_be_nil()
                    table.insert(test_ctx.created_embeddings, embedding_result.id)
                end

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.DELETE_NODES, {
                    ids = node_ids
                })

                expect(err).to_be_nil()
                expect(#result.ids).to_equal(3)
                expect(result.total_deleted).to_equal(3)
            end)

            it("should handle JSON metadata correctly", function()
                local node_id = uuid.v7()
                local complex_metadata = {
                    tags = {"test", "example", "complex"},
                    properties = {
                        importance = "high",
                        category = "documentation"
                    },
                    numbers = {1, 2, 3, 4, 5},
                    nested = {
                        deep = {
                            value = "nested_value"
                        }
                    }
                }

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id,
                    node_type = "document",
                    content = "Test document with complex metadata",
                    metadata = complex_metadata
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(node_id)
                table.insert(test_ctx.created_nodes, node_id)
            end)
        end)

        describe("Embed Operation Tracking", function()
            it("should create embed operation successfully", function()
                local operation_id = uuid.v7()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_EMBED_OPERATION, {
                    id = operation_id,
                    component_id = test_ctx.kb_id,
                    upload_uuid = "test-upload-" .. uuid.v7(),
                    status = "processing"
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(operation_id)
                expect(result.component_id).to_equal(test_ctx.kb_id)
                expect(result.status).to_equal("processing")
                table.insert(test_ctx.created_operations, operation_id)
            end)

            it("should error when creating operation without id", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_EMBED_OPERATION, {
                    component_id = test_ctx.kb_id,
                    upload_uuid = "test-upload"
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should error when creating operation without component_id", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_EMBED_OPERATION, {
                    id = uuid.v7(),
                    upload_uuid = "test-upload"
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should error when creating operation without upload_uuid", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_EMBED_OPERATION, {
                    id = uuid.v7(),
                    component_id = test_ctx.kb_id
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should default status to processing", function()
                local operation_id = uuid.v7()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_EMBED_OPERATION, {
                    id = operation_id,
                    component_id = test_ctx.kb_id,
                    upload_uuid = "test-upload-" .. uuid.v7()
                })

                expect(err).to_be_nil()
                expect(result.status).to_equal("processing")
                table.insert(test_ctx.created_operations, operation_id)
            end)

            it("should update operation status to completed", function()
                local operation_id = uuid.v7()

                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_EMBED_OPERATION, {
                    id = operation_id,
                    component_id = test_ctx.kb_id,
                    upload_uuid = "test-upload-" .. uuid.v7()
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_operations, operation_id)

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_EMBED_OPERATION_STATUS, {
                    id = operation_id,
                    status = "completed",
                    ops_executed = 42
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(operation_id)
                expect(result.status).to_equal("completed")
            end)

            it("should update operation status to failed with error message", function()
                local operation_id = uuid.v7()

                local create_result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_EMBED_OPERATION, {
                    id = operation_id,
                    component_id = test_ctx.kb_id,
                    upload_uuid = "test-upload-" .. uuid.v7()
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_operations, operation_id)

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_EMBED_OPERATION_STATUS, {
                    id = operation_id,
                    status = "failed",
                    ops_executed = 0,
                    error = "Embedding model unavailable"
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(operation_id)
                expect(result.status).to_equal("failed")
            end)

            it("should error when updating non-existent operation", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_EMBED_OPERATION_STATUS, {
                    id = uuid.v7(),
                    status = "completed",
                    ops_executed = 0
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should error when updating without id", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_EMBED_OPERATION_STATUS, {
                    status = "completed"
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)
        end)

        describe("Error Handling", function()
            it("should handle nil KB ID properly", function()
                local db, err = sql.get("app:db")
                if err then error("Failed to get database: " .. err) end

                local tx, err = db:begin()
                if err then
                    db:release()
                    error("Failed to begin transaction: " .. err)
                end

                local command = {
                    type = ops.COMMAND_TYPES.CREATE_NODE,
                    payload = {
                        node_type = "document",
                        content = "Test"
                    }
                }

                local result, err = ops.handlers[ops.COMMAND_TYPES.CREATE_NODE](tx, nil, uuid.v7(), command)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()

                tx:rollback()
                db:release()
            end)

            it("should handle metadata as table correctly", function()
                local node_id = uuid.v7()

                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id,
                    node_type = "document",
                    content = "Test document",
                    metadata = {valid = "table", works = true}
                })

                expect(err).to_be_nil()
                expect(result.id).to_equal(node_id)
                table.insert(test_ctx.created_nodes, node_id)

                local node_id_2 = uuid.v7()
                local result_2, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id_2,
                    node_type = "document",
                    content = "Test document 2",
                    metadata = '{"valid": "json", "works": true}'
                })

                expect(err).to_be_nil()
                expect(result_2.id).to_equal(node_id_2)
                table.insert(test_ctx.created_nodes, node_id_2)
            end)

            it("should handle parent not found error", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    parent_id = uuid.v7(),
                    node_type = "document",
                    content = "Child document"
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should handle invalid component ID for update", function()
                local result, err = execute_op_with_commit(ops.COMMAND_TYPES.UPDATE_COMPONENT, {
                    id = uuid.v7(),
                    config = {test = true}
                })

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
            end)

            it("should handle database constraint violations", function()
                local node_id = uuid.v7()

                local result1, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id,
                    node_type = "document",
                    content = "First node"
                })
                expect(err).to_be_nil()
                table.insert(test_ctx.created_nodes, node_id)

                local result2, err = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, {
                    id = node_id,
                    node_type = "document",
                    content = "Duplicate node"
                })

                expect(result2).to_be_nil()
                expect(err).not_to_be_nil()
            end)
        end)
    end)
end

return test.run_cases(run_tests)