local test = require("test")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local sql = require("sql")
local ops = require("ops")
local consts = require("drafling_consts")

local function define_tests()
    describe("Operations Module", function()
        local test_ctx = {
            cleanup_project_ids = {},
            test_user_id = "ops-user-" .. uuid.v7(),
            db = nil,
            -- Transaction context - accessible to both tests and cleanup
            current_tx = nil,
            current_project_id = nil,
            current_category_id = nil
        }

        local function get_test_db()
            if not test_ctx.db then
                local db, err = sql.get(consts.APP_DB)
                if err then error("Failed to connect to database: " .. err) end
                test_ctx.db = db
            end
            return test_ctx.db
        end

        local function register_for_cleanup(project_id)
            if project_id then
                table.insert(test_ctx.cleanup_project_ids, project_id)
            end
        end

        -- Setup: Create a transaction for each test
        before_each(function()
            local db = get_test_db()
            local tx, err = db:begin()
            if err then
                error("Failed to begin transaction: " .. err)
            end
            test_ctx.current_tx = tx
        end)

        -- Teardown: Always clean up transaction, regardless of test outcome
        after_each(function()
            if test_ctx.current_tx then
                test_ctx.current_tx:rollback()
                test_ctx.current_tx = nil
            end
            -- Reset per-test state
            test_ctx.current_project_id = nil
            test_ctx.current_category_id = nil
        end)

        after_all(function()
            if #test_ctx.cleanup_project_ids == 0 then
                if test_ctx.db then test_ctx.db:release() end
                return
            end

            local db = get_test_db()
            local tx, err_tx = db:begin()
            if err_tx then
                print("ERROR: Failed to begin cleanup transaction")
                if test_ctx.db then test_ctx.db:release() end
                return
            end

            for _, doc_id in ipairs(test_ctx.cleanup_project_ids) do
                tx:execute("DELETE FROM drafling_projects WHERE project_id = ?", { doc_id })
            end

            tx:commit()
            if test_ctx.db then test_ctx.db:release() end
        end)

        -- Helper to set up a test project in the current transaction
        local function setup_test_project()
            local tx = test_ctx.current_tx
            local project_id = uuid.v7()
            local now_ts = time.now():format(time.RFC3339NANO)

            tx:execute([[
                INSERT INTO drafling_projects (project_id, user_id, project_type, title, status, metadata, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ]], { project_id, test_ctx.test_user_id, "test_type", "Test Document", consts.STATUS.DRAFT, "{}", now_ts, now_ts })

            test_ctx.current_project_id = project_id
            register_for_cleanup(project_id)
            return project_id
        end

        -- Helper to set up a test project with category
        local function setup_with_category()
            local project_id = setup_test_project()
            local tx = test_ctx.current_tx

            local category_command = {
                type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                payload = {
                    project_id = project_id,
                    name = "test_category",
                    display_name = "Test Category"
                }
            }

            local cat_result, cat_err = ops.execute(tx, category_command)
            expect(cat_err).to_be_nil()

            local category_id = cat_result.results[1].category_id
            test_ctx.current_category_id = category_id
            return project_id, category_id
        end

        describe("Basic Operation Execution", function()
            it("should execute a single command successfully", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                    payload = {
                        project_id = project_id,
                        name = "test_category",
                        display_name = "Test Category",
                        metadata = { type = "test" }
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(1)
                expect(result.results[1].category_id).not_to_be_nil()
                expect(result.results[1].changes_made).to_be_true()

                local query = "SELECT * FROM drafling_categories WHERE category_id = ?"
                local rows, err_query = tx:query(query, { result.results[1].category_id })

                expect(err_query).to_be_nil()
                expect(#rows).to_equal(1)
                expect(rows[1].name).to_equal("test_category")
            end)

            it("should execute multiple commands in a batch", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local commands = {
                    {
                        type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                        payload = {
                            project_id = project_id,
                            name = "category1",
                            display_name = "Category 1"
                        }
                    },
                    {
                        type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                        payload = {
                            project_id = project_id,
                            name = "category2",
                            display_name = "Category 2"
                        }
                    }
                }

                local result, err = ops.execute(tx, commands)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(2)

                local query = "SELECT * FROM drafling_categories WHERE project_id = ? ORDER BY name"
                local rows, err_query = tx:query(query, { project_id })

                expect(err_query).to_be_nil()
                expect(#rows).to_equal(2)
                expect(rows[1].name).to_equal("category1")
                expect(rows[2].name).to_equal("category2")
            end)

            it("should fail with missing project ID", function()
                local tx = test_ctx.current_tx

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                    payload = {
                        name = "test_category"
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Missing required field")
                expect(err).to_contain("project_id")
            end)

            it("should fail with unknown command type", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local command = {
                    type = "UNKNOWN_OPERATION",
                    payload = {}
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Unknown command type")
            end)

            it("should handle command failure in batch correctly", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local commands = {
                    {
                        type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                        payload = {
                            project_id = project_id,
                            name = "valid_category",
                            display_name = "Valid Category"
                        }
                    },
                    {
                        type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                        payload = {
                            project_id = project_id,
                            -- Missing required 'name' field
                            display_name = "Invalid Category"
                        }
                    }
                }

                local result, err = ops.execute(tx, commands)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()

                -- Since ops.execute processes sequentially, the first command succeeded
                local query = "SELECT COUNT(*) as count FROM drafling_categories WHERE project_id = ?"
                local rows, err_query = tx:query(query, { project_id })

                expect(err_query).to_be_nil()
                expect(rows[1].count).to_equal(1) -- First command succeeded
            end)
        end)

        describe("Document Operations", function()
            it("should create a project", function()
                local tx = test_ctx.current_tx
                local project_id = uuid.v7()

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_PROJECT,
                    payload = {
                        project_id = project_id,
                        user_id = test_ctx.test_user_id,
                        project_type = "create_test",
                        title = "Created Document",
                        metadata = { source = "test" }
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].project_id).to_equal(project_id)

                local query = "SELECT * FROM drafling_projects WHERE project_id = ?"
                local rows, err_query = tx:query(query, { project_id })

                expect(err_query).to_be_nil()
                expect(#rows).to_equal(1)
                expect(rows[1].title).to_equal("Created Document")
                expect(rows[1].status).to_equal(consts.STATUS.DRAFT)

                register_for_cleanup(project_id)
                -- We'll commit this one since it's a successful creation test
                tx:commit()
                test_ctx.current_tx = nil -- Mark as committed so after_each doesn't rollback
            end)

            it("should update a project", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local command = {
                    type = ops.OPERATION_TYPE.UPDATE_PROJECT,
                    payload = {
                        project_id = project_id,
                        title = "Updated Title",
                        status = consts.STATUS.ACTIVE,
                        metadata = { updated = true }
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].rows_affected).to_equal(1)

                local query = "SELECT * FROM drafling_projects WHERE project_id = ?"
                local rows, err_query = tx:query(query, { project_id })

                expect(err_query).to_be_nil()
                expect(rows[1].title).to_equal("Updated Title")
                expect(rows[1].status).to_equal(consts.STATUS.ACTIVE)

                local metadata = json.decode(rows[1].metadata)
                expect(metadata.updated).to_be_true()
            end)

            it("should delete a project", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local command = {
                    type = ops.OPERATION_TYPE.DELETE_PROJECT,
                    payload = {
                        project_id = project_id
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].rows_affected).to_equal(1)

                local query = "SELECT COUNT(*) as count FROM drafling_projects WHERE project_id = ?"
                local rows, err_query = tx:query(query, { project_id })

                expect(err_query).to_be_nil()
                expect(rows[1].count).to_equal(0)
            end)

            it("should fail to create project without required fields", function()
                local tx = test_ctx.current_tx
                local project_id = uuid.v7()

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_PROJECT,
                    payload = {
                        project_id = project_id,
                        user_id = test_ctx.test_user_id
                        -- Missing project_type
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Missing required field")
                expect(err).to_contain("project_type")
            end)

            it("should handle empty update gracefully", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local command = {
                    type = ops.OPERATION_TYPE.UPDATE_PROJECT,
                    payload = {
                        project_id = project_id
                        -- No fields to update
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_false()
                expect(result.results[1].message).to_contain("No fields provided for update")
            end)
        end)

        describe("Category Operations", function()
            it("should create a category", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                    payload = {
                        project_id = project_id,
                        name = "input",
                        display_name = "Input Data",
                        metadata = { type = "data_input" }
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].category_id).not_to_be_nil()

                local query = "SELECT * FROM drafling_categories WHERE category_id = ?"
                local rows, err_query = tx:query(query, { result.results[1].category_id })

                expect(err_query).to_be_nil()
                expect(#rows).to_equal(1)
                expect(rows[1].name).to_equal("input")
                expect(rows[1].display_name).to_equal("Input Data")
                expect(rows[1].project_id).to_equal(project_id)

                local metadata = json.decode(rows[1].metadata)
                expect(metadata.type).to_equal("data_input")
            end)

            it("should update a category", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local update_command = {
                    type = ops.OPERATION_TYPE.UPDATE_CATEGORY,
                    payload = {
                        category_id = category_id,
                        display_name = "Updated Output Data",
                        metadata = { updated = true }
                    }
                }

                local result, err = ops.execute(tx, update_command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].rows_affected).to_equal(1)

                local query = "SELECT * FROM drafling_categories WHERE category_id = ?"
                local rows, err_query = tx:query(query, { category_id })

                expect(err_query).to_be_nil()
                expect(rows[1].display_name).to_equal("Updated Output Data")

                local metadata = json.decode(rows[1].metadata)
                expect(metadata.updated).to_be_true()
            end)

            it("should delete a category", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local delete_command = {
                    type = ops.OPERATION_TYPE.DELETE_CATEGORY,
                    payload = {
                        category_id = category_id
                    }
                }

                local result, err = ops.execute(tx, delete_command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].rows_affected).to_equal(1)

                local query = "SELECT COUNT(*) as count FROM drafling_categories WHERE category_id = ?"
                local rows, err_query = tx:query(query, { category_id })

                expect(err_query).to_be_nil()
                expect(rows[1].count).to_equal(0)
            end)

            it("should fail to create category without name", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                    payload = {
                        project_id = project_id,
                        display_name = "No Name Category"
                        -- Missing required 'name' field
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Missing required field")
                expect(err).to_contain("name")
            end)

            it("should handle empty category update", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local update_command = {
                    type = ops.OPERATION_TYPE.UPDATE_CATEGORY,
                    payload = {
                        category_id = category_id
                        -- No fields to update
                    }
                }

                local result, err = ops.execute(tx, update_command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_false()
                expect(result.results[1].message).to_contain("No fields provided for update")
            end)
        end)

        describe("Entry Operations", function()
            it("should create an entry", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = category_id,
                        type = "text",
                        content = "Test entry content",
                        title = "Test Entry",
                        status = consts.STATUS.ACTIVE,
                        metadata = { source = "user" }
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].entry_id).not_to_be_nil()
                expect(result.results[1].history_id).not_to_be_nil()

                local query = "SELECT * FROM drafling_entries WHERE entry_id = ?"
                local rows, err_query = tx:query(query, { result.results[1].entry_id })

                expect(err_query).to_be_nil()
                expect(#rows).to_equal(1)
                expect(rows[1].type).to_equal("text")
                expect(rows[1].content).to_equal("Test entry content")
                expect(rows[1].title).to_equal("Test Entry")
                expect(rows[1].status).to_equal(consts.STATUS.ACTIVE)

                local history_query = "SELECT * FROM drafling_entry_history WHERE entry_id = ?"
                local history_rows, history_err = tx:query(history_query, { result.results[1].entry_id })

                expect(history_err).to_be_nil()
                expect(#history_rows).to_equal(1)
                expect(history_rows[1].operation_type).to_equal(consts.HISTORY_OPERATION.CREATE)
            end)

            it("should update an entry", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local create_command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = category_id,
                        type = "text",
                        content = "Original content",
                        title = "Original Label"
                    }
                }

                local create_result, create_err = ops.execute(tx, create_command)
                expect(create_err).to_be_nil()

                local entry_id = create_result.results[1].entry_id

                local update_command = {
                    type = ops.OPERATION_TYPE.UPDATE_ENTRY,
                    payload = {
                        entry_id = entry_id,
                        content = "Updated content",
                        title = "Updated Label",
                        status = consts.STATUS.PUBLISHED,
                        metadata = { updated = true }
                    }
                }

                local result, err = ops.execute(tx, update_command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].rows_affected).to_equal(1)
                expect(result.results[1].history_id).not_to_be_nil()

                local query = "SELECT * FROM drafling_entries WHERE entry_id = ?"
                local rows, err_query = tx:query(query, { entry_id })

                expect(err_query).to_be_nil()
                expect(rows[1].content).to_equal("Updated content")
                expect(rows[1].title).to_equal("Updated Label")
                expect(rows[1].status).to_equal(consts.STATUS.PUBLISHED)

                local history_query = "SELECT * FROM drafling_entry_history WHERE entry_id = ? ORDER BY created_at"
                local history_rows, history_err = tx:query(history_query, { entry_id })

                expect(history_err).to_be_nil()
                expect(#history_rows).to_equal(2)
                expect(history_rows[2].operation_type).to_equal(consts.HISTORY_OPERATION.UPDATE)

                local changes = json.decode(history_rows[2].changes)
                expect(changes.fields_changed).to_be_type("table")
                expect(#changes.fields_changed >= 3).to_be_true()
            end)

            it("should delete an entry", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local create_command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = category_id,
                        type = "text",
                        content = "To be deleted",
                        title = "Delete Me"
                    }
                }

                local create_result, create_err = ops.execute(tx, create_command)
                expect(create_err).to_be_nil()

                local entry_id = create_result.results[1].entry_id

                local delete_command = {
                    type = ops.OPERATION_TYPE.DELETE_ENTRY,
                    payload = {
                        entry_id = entry_id
                    }
                }

                local result, err = ops.execute(tx, delete_command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(result.results[1].rows_affected).to_equal(1)
                expect(result.results[1].history_id).not_to_be_nil()

                local query = "SELECT COUNT(*) as count FROM drafling_entries WHERE entry_id = ?"
                local rows, err_query = tx:query(query, { entry_id })

                expect(err_query).to_be_nil()
                expect(rows[1].count).to_equal(0)

                local history_query = "SELECT * FROM drafling_entry_history WHERE entry_id = ? ORDER BY created_at"
                local history_rows, history_err = tx:query(history_query, { entry_id })

                expect(history_err).to_be_nil()
                expect(#history_rows).to_equal(2)
                expect(history_rows[2].operation_type).to_equal(consts.HISTORY_OPERATION.DELETE)
            end)

            it("should fail to create entry without required fields", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = category_id
                        -- Missing required 'type' field
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Missing required field")
                expect(err).to_contain("type")
            end)

            it("should fail to create entry with non-existent category", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = uuid.v7(), -- Non-existent category
                        type = "text",
                        content = "Should fail",
                        title = "Fail"
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Category does not belong to the specified project")
            end)

            it("should handle entry update with no changes", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local create_command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = category_id,
                        type = "text",
                        content = "Unchanged content",
                        title = "Unchanged Label"
                    }
                }

                local create_result, create_err = ops.execute(tx, create_command)
                expect(create_err).to_be_nil()

                local entry_id = create_result.results[1].entry_id

                local update_command = {
                    type = ops.OPERATION_TYPE.UPDATE_ENTRY,
                    payload = {
                        entry_id = entry_id,
                        type = "text",
                        content = "Unchanged content",
                        title = "Unchanged Label"
                    }
                }

                local result, err = ops.execute(tx, update_command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_false()
                expect(result.results[1].message).to_contain("No fields provided for update")
            end)

            it("should create entry with complex content", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local complex_content = {
                    data = { 1, 2, 3 },
                    config = { enabled = true, timeout = 30 },
                    metadata = { source = "api", timestamp = "2024-01-01" }
                }

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = category_id,
                        type = "json",
                        content = json.encode(complex_content),
                        content_type = consts.CONTENT_TYPE.APPLICATION_JSON,
                        title = "Complex Entry"
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()

                local query = "SELECT * FROM drafling_entries WHERE entry_id = ?"
                local rows, err_query = tx:query(query, { result.results[1].entry_id })

                expect(err_query).to_be_nil()
                expect(rows[1].content_type).to_equal(consts.CONTENT_TYPE.APPLICATION_JSON)

                local parsed_content = json.decode(rows[1].content)
                expect(parsed_content.data).to_be_type("table")
                expect(#parsed_content.data).to_equal(3)
                expect(parsed_content.config.enabled).to_be_true()
            end)
        end)

        describe("Error Handling", function()
            it("should handle JSON encoding errors", function()
                local tx = test_ctx.current_tx
                local project_id = setup_test_project()

                -- Create a circular reference that can't be JSON encoded
                local function circular_table()
                    local t = {}
                    t.self = t
                    return t
                end

                local command = {
                    type = ops.OPERATION_TYPE.CREATE_CATEGORY,
                    payload = {
                        project_id = project_id,
                        name = "test_category",
                        metadata = circular_table()
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Failed to encode JSON")
            end)

            it("should handle missing entry for update", function()
                local tx = test_ctx.current_tx

                local command = {
                    type = ops.OPERATION_TYPE.UPDATE_ENTRY,
                    payload = {
                        entry_id = uuid.v7(), -- Non-existent entry
                        content = "Updated content"
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Entry not found")
            end)

            it("should handle missing entry for delete", function()
                local tx = test_ctx.current_tx

                local command = {
                    type = ops.OPERATION_TYPE.DELETE_ENTRY,
                    payload = {
                        entry_id = uuid.v7() -- Non-existent entry
                    }
                }

                local result, err = ops.execute(tx, command)

                expect(result).to_be_nil()
                expect(err).to_contain("Entry not found")
            end)
        end)

        describe("History Creation", function()
            it("should create history for entry operations", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local create_command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = category_id,
                        type = "text",
                        content = "Original content",
                        title = "Original Label"
                    }
                }

                local create_result, create_err = ops.execute(tx, create_command)
                expect(create_err).to_be_nil()

                local entry_id = create_result.results[1].entry_id

                local update_command = {
                    type = ops.OPERATION_TYPE.UPDATE_ENTRY,
                    payload = {
                        entry_id = entry_id,
                        content = "Updated content"
                    }
                }

                local update_result, update_err = ops.execute(tx, update_command)
                expect(update_err).to_be_nil()

                local delete_command = {
                    type = ops.OPERATION_TYPE.DELETE_ENTRY,
                    payload = {
                        entry_id = entry_id
                    }
                }

                local delete_result, delete_err = ops.execute(tx, delete_command)
                expect(delete_err).to_be_nil()

                local history_query = "SELECT * FROM drafling_entry_history WHERE entry_id = ? ORDER BY created_at"
                local history_rows, history_err = tx:query(history_query, { entry_id })

                expect(history_err).to_be_nil()
                expect(#history_rows).to_equal(3)

                expect(history_rows[1].operation_type).to_equal(consts.HISTORY_OPERATION.CREATE)
                expect(history_rows[2].operation_type).to_equal(consts.HISTORY_OPERATION.UPDATE)
                expect(history_rows[3].operation_type).to_equal(consts.HISTORY_OPERATION.DELETE)

                local create_changes = json.decode(history_rows[1].changes)
                expect(create_changes.operation).to_equal("create")
                expect(create_changes.initial_values).to_be_type("table")

                local update_changes = json.decode(history_rows[2].changes)
                expect(update_changes.fields_changed).to_be_type("table")
                expect(update_changes.from).to_be_type("table")
                expect(update_changes.to).to_be_type("table")

                local delete_changes = json.decode(history_rows[3].changes)
                expect(delete_changes.operation).to_equal("delete")
                expect(delete_changes.deleted_values).to_be_type("table")
            end)

            it("should track field changes in history", function()
                local tx = test_ctx.current_tx
                local project_id, category_id = setup_with_category()

                local create_command = {
                    type = ops.OPERATION_TYPE.CREATE_ENTRY,
                    payload = {
                        project_id = project_id,
                        category_id = category_id,
                        type = "text",
                        content = "Original content",
                        title = "Original Label",
                        status = consts.STATUS.DRAFT
                    }
                }

                local create_result, create_err = ops.execute(tx, create_command)
                expect(create_err).to_be_nil()

                local entry_id = create_result.results[1].entry_id

                local update_command = {
                    type = ops.OPERATION_TYPE.UPDATE_ENTRY,
                    payload = {
                        entry_id = entry_id,
                        content = "Updated content",
                        status = consts.STATUS.ACTIVE
                    }
                }

                local update_result, update_err = ops.execute(tx, update_command)
                expect(update_err).to_be_nil()

                local history_query = "SELECT * FROM drafling_entry_history WHERE entry_id = ? AND operation_type = ? ORDER BY created_at DESC LIMIT 1"
                local history_rows, history_err = tx:query(history_query, { entry_id, consts.HISTORY_OPERATION.UPDATE })

                expect(history_err).to_be_nil()
                expect(#history_rows).to_equal(1)

                local changes = json.decode(history_rows[1].changes)
                expect(changes.fields_changed).to_be_type("table")

                local changed_fields = {}
                for _, field in ipairs(changes.fields_changed) do
                    changed_fields[field] = true
                end

                expect(changed_fields["content"]).to_be_true()
                expect(changed_fields["status"]).to_be_true()
                expect(changed_fields["title"]).to_be_nil()

                expect(changes.from.content).to_equal("Original content")
                expect(changes.to.content).to_equal("Updated content")
                expect(changes.from.status).to_equal(consts.STATUS.DRAFT)
                expect(changes.to.status).to_equal(consts.STATUS.ACTIVE)
            end)
        end)
    end)
end

return test.run_cases(define_tests)