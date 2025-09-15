local test = require("test")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local sql = require("sql")
local writer = require("writer")
local ops = require("ops")
local consts = require("drafling_consts")

local function define_tests()
    describe("Drafling Writer", function()
        local test_ctx = {
            cleanup_project_ids = {},
            test_user_id = "writer-user-" .. uuid.v7(),
            mock_messages = {},
            db = nil
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

        local function clear_mock_messages()
            test_ctx.mock_messages = {}
        end

        -- Mock process messaging for testing
        local original_send_message = writer._send_process_message
        local original_get_timestamp = writer._get_current_timestamp

        before_all(function()
            -- Mock process messaging
            writer._send_process_message = function(target_process, topic, payload)
                table.insert(test_ctx.mock_messages, {
                    target_process = target_process,
                    topic = topic,
                    payload = payload
                })
            end

            -- Mock timestamp for consistent testing
            writer._get_current_timestamp = function()
                return "2024-01-01T12:00:00.000Z"
            end
        end)

        after_all(function()
            -- Restore original functions
            writer._send_process_message = original_send_message
            writer._get_current_timestamp = original_get_timestamp

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

        after_each(function()
            clear_mock_messages()
        end)

        describe("Fluent Batch Builder", function()
            it("should create batch for user with auto-generated project ID", function()
                local batch, err = writer.for_user(test_ctx.test_user_id)
                expect(err).to_be_nil()
                expect(batch).not_to_be_nil()
                expect(batch.user_id).to_equal(test_ctx.test_user_id)
                expect(batch.project_id).not_to_be_nil()
                expect(batch.auto_generate_doc_id).to_be_true()
            end)

            it("should create batch for specific project", function()
                local project_id = uuid.v7()
                local batch, err = writer.for_project(test_ctx.test_user_id, project_id)

                expect(err).to_be_nil()
                expect(batch).not_to_be_nil()
                expect(batch.user_id).to_equal(test_ctx.test_user_id)
                expect(batch.project_id).to_equal(project_id)
                expect(batch.auto_generate_doc_id).to_be_false()
            end)

            it("should fail without user ID", function()
                local batch1, err1 = writer.for_user(nil)
                expect(batch1).to_be_nil()
                expect(err1).to_contain("Missing required field")
                expect(err1).to_contain("user_id")

                local batch2, err2 = writer.for_user("")
                expect(batch2).to_be_nil()
                expect(err2).to_contain("Missing required field")

                local batch3, err3 = writer.for_project(nil, uuid.v7())
                expect(batch3).to_be_nil()
                expect(err3).to_contain("Missing required field")
            end)
        end)

        describe("Document Operations", function()
            it("should create a project using fluent API", function()
                clear_mock_messages()

                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, create_err = batch:create_project("test_type", "Test Document", { priority = "high" })
                expect(create_err).to_be_nil()

                local result, err = batch2:execute()

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(1)
                expect(result.results[1].project_id).not_to_be_nil()

                register_for_cleanup(result.results[1].project_id)

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT * FROM drafling_projects WHERE project_id = ?", { result.results[1].project_id })

                expect(query_err).to_be_nil()
                expect(#rows).to_equal(1)
                expect(rows[1].title).to_equal("Test Document")
                expect(rows[1].project_type).to_equal("test_type")

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("project_created")
            end)

            it("should update a project using fluent API", function()
                clear_mock_messages()

                -- Create project first
                local create_batch, create_batch_err = writer.for_user(test_ctx.test_user_id)
                expect(create_batch_err).to_be_nil()

                local create_batch2, create_doc_err = create_batch:create_project("update_test", "Original Title")
                expect(create_doc_err).to_be_nil()

                local create_result, create_err = create_batch2:execute()
                expect(create_err).to_be_nil()

                register_for_cleanup(create_result.results[1].project_id)

                clear_mock_messages()

                -- Update project
                local update_batch, update_batch_err = writer.for_project(test_ctx.test_user_id, create_result.results[1].project_id)
                expect(update_batch_err).to_be_nil()

                local update_batch2, update_doc_err = update_batch:update_project({ title = "Updated Title", status = consts.STATUS.ACTIVE })
                expect(update_doc_err).to_be_nil()

                local result, err = update_batch2:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(1)

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT * FROM drafling_projects WHERE project_id = ?", { create_result.results[1].project_id })

                expect(query_err).to_be_nil()
                expect(rows[1].title).to_equal("Updated Title")
                expect(rows[1].status).to_equal(consts.STATUS.ACTIVE)

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("project_updated")
            end)

            it("should delete a project using fluent API", function()
                clear_mock_messages()

                -- Create project first
                local create_batch, create_batch_err = writer.for_user(test_ctx.test_user_id)
                expect(create_batch_err).to_be_nil()

                local create_batch2, create_doc_err = create_batch:create_project("delete_test", "To Delete")
                expect(create_doc_err).to_be_nil()

                local create_result, create_err = create_batch2:execute()
                expect(create_err).to_be_nil()

                clear_mock_messages()

                -- Delete project
                local delete_batch, delete_batch_err = writer.for_project(test_ctx.test_user_id, create_result.results[1].project_id)
                expect(delete_batch_err).to_be_nil()

                local delete_batch2, delete_doc_err = delete_batch:delete_project()
                expect(delete_doc_err).to_be_nil()

                local result, err = delete_batch2:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT COUNT(*) as count FROM drafling_projects WHERE project_id = ?", { create_result.results[1].project_id })

                expect(query_err).to_be_nil()
                expect(rows[1].count).to_equal(0)

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("project_deleted")
            end)

            it("should fail to create project without required fields", function()
                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, create_err = batch:create_project(nil, "Test Document")
                expect(batch2).to_be_nil()
                expect(create_err).to_contain("Missing required field")
                expect(create_err).to_contain("project_type")
            end)
        end)

        describe("Category Operations", function()
            local function setup_test_project()
                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, create_err = batch:create_project("category_test", "Category Test Doc")
                expect(create_err).to_be_nil()

                local result, err = batch2:execute()
                expect(err).to_be_nil()

                register_for_cleanup(result.results[1].project_id)
                return result.results[1].project_id
            end

            it("should create categories using fluent API", function()
                clear_mock_messages()
                local project_id = setup_test_project()
                clear_mock_messages()

                local batch, batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(batch_err).to_be_nil()

                local batch2, cat1_err = batch:create_category("input", "Input Data", { type = "data" })
                expect(cat1_err).to_be_nil()

                local batch3, cat2_err = batch2:create_category("output", "Output Results", { type = "results" })
                expect(cat2_err).to_be_nil()

                local result, err = batch3:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(2)

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT * FROM drafling_categories WHERE project_id = ? ORDER BY name", { project_id })

                expect(query_err).to_be_nil()
                expect(#rows).to_equal(2)
                expect(rows[1].name).to_equal("input")
                expect(rows[2].name).to_equal("output")

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(2)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("category_created")
                expect(test_ctx.mock_messages[2].payload.event_type).to_equal("category_created")
            end)

            it("should update categories using fluent API", function()
                clear_mock_messages()
                local project_id = setup_test_project()

                -- Create category first
                local create_batch, create_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(create_batch_err).to_be_nil()

                local create_batch2, create_cat_err = create_batch:create_category("notes", "Notes")
                expect(create_cat_err).to_be_nil()

                local create_result, create_err = create_batch2:execute()
                expect(create_err).to_be_nil()

                clear_mock_messages()

                local category_id = create_result.results[1].category_id

                -- Update category
                local update_batch, update_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(update_batch_err).to_be_nil()

                local update_batch2, update_cat_err = update_batch:update_category(category_id, { display_name = "Updated Notes", metadata = { updated = true } })
                expect(update_cat_err).to_be_nil()

                local result, err = update_batch2:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT * FROM drafling_categories WHERE category_id = ?", { category_id })

                expect(query_err).to_be_nil()
                expect(rows[1].display_name).to_equal("Updated Notes")

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("category_updated")
            end)

            it("should delete categories using fluent API", function()
                clear_mock_messages()
                local project_id = setup_test_project()

                -- Create category first
                local create_batch, create_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(create_batch_err).to_be_nil()

                local create_batch2, create_cat_err = create_batch:create_category("temp", "Temporary")
                expect(create_cat_err).to_be_nil()

                local create_result, create_err = create_batch2:execute()
                expect(create_err).to_be_nil()

                clear_mock_messages()

                local category_id = create_result.results[1].category_id

                -- Delete category
                local delete_batch, delete_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(delete_batch_err).to_be_nil()

                local delete_batch2, delete_cat_err = delete_batch:delete_category(category_id)
                expect(delete_cat_err).to_be_nil()

                local result, err = delete_batch2:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT COUNT(*) as count FROM drafling_categories WHERE category_id = ?", { category_id })

                expect(query_err).to_be_nil()
                expect(rows[1].count).to_equal(0)

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("category_deleted")
            end)

            it("should fail to create category without required fields", function()
                local project_id = setup_test_project()

                local batch, batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(batch_err).to_be_nil()

                local batch2, create_err = batch:create_category(nil, "No Name Category")
                expect(batch2).to_be_nil()
                expect(create_err).to_contain("Missing required field")
                expect(create_err).to_contain("name")
            end)
        end)

        describe("Entry Operations", function()
            local function setup_with_category()
                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, doc_err = batch:create_project("entry_test", "Entry Test Doc")
                expect(doc_err).to_be_nil()

                local batch3, cat_err = batch2:create_category("test_cat", "Test Category")
                expect(cat_err).to_be_nil()

                local result, err = batch3:execute()
                expect(err).to_be_nil()

                register_for_cleanup(result.results[1].project_id)

                return result.results[1].project_id, result.results[2].category_id
            end

            it("should create entries using fluent API", function()
                clear_mock_messages()
                local project_id, category_id = setup_with_category()
                clear_mock_messages()

                local batch, batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(batch_err).to_be_nil()

                local batch2, entry_err = batch:create_entry(category_id, "text", "Test content", consts.CONTENT_TYPE.TEXT_PLAIN, "Test Label", consts.STATUS.ACTIVE, { source = "user" })
                expect(entry_err).to_be_nil()

                local result, err = batch2:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(1)

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT * FROM drafling_entries WHERE entry_id = ?", { result.results[1].entry_id })

                expect(query_err).to_be_nil()
                expect(#rows).to_equal(1)
                expect(rows[1].content).to_equal("Test content")
                expect(rows[1].type).to_equal("text")

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("entry_created")
            end)

            it("should update entries using fluent API", function()
                clear_mock_messages()
                local project_id, category_id = setup_with_category()

                -- Create entry first
                local create_batch, create_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(create_batch_err).to_be_nil()

                local create_batch2, create_entry_err = create_batch:create_entry(category_id, "text", "Original content", consts.CONTENT_TYPE.TEXT_PLAIN, "Original Label")
                expect(create_entry_err).to_be_nil()

                local create_result, create_err = create_batch2:execute()
                expect(create_err).to_be_nil()

                clear_mock_messages()

                local entry_id = create_result.results[1].entry_id

                -- Update entry
                local update_batch, update_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(update_batch_err).to_be_nil()

                local update_batch2, update_entry_err = update_batch:update_entry(entry_id, { content = "Updated content", title = "Updated Label", status = consts.STATUS.PUBLISHED })
                expect(update_entry_err).to_be_nil()

                local result, err = update_batch2:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT * FROM drafling_entries WHERE entry_id = ?", { entry_id })

                expect(query_err).to_be_nil()
                expect(rows[1].content).to_equal("Updated content")
                expect(rows[1].title).to_equal("Updated Label")
                expect(rows[1].status).to_equal(consts.STATUS.PUBLISHED)

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("entry_updated")
            end)

            it("should delete entries using fluent API", function()
                clear_mock_messages()
                local project_id, category_id = setup_with_category()

                -- Create entry first
                local create_batch, create_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(create_batch_err).to_be_nil()

                local create_batch2, create_entry_err = create_batch:create_entry(category_id, "text", "To delete", consts.CONTENT_TYPE.TEXT_PLAIN, "Delete Me")
                expect(create_entry_err).to_be_nil()

                local create_result, create_err = create_batch2:execute()
                expect(create_err).to_be_nil()

                clear_mock_messages()

                local entry_id = create_result.results[1].entry_id

                -- Delete entry
                local delete_batch, delete_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(delete_batch_err).to_be_nil()

                local delete_batch2, delete_entry_err = delete_batch:delete_entry(entry_id)
                expect(delete_entry_err).to_be_nil()

                local result, err = delete_batch2:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()

                -- Check database
                local db = get_test_db()
                local rows, query_err = db:query("SELECT COUNT(*) as count FROM drafling_entries WHERE entry_id = ?", { entry_id })

                expect(query_err).to_be_nil()
                expect(rows[1].count).to_equal(0)

                -- Check publishing
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("entry_deleted")
            end)

            it("should fail to create entry without required fields", function()
                local project_id, category_id = setup_with_category()

                local batch, batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(batch_err).to_be_nil()

                local batch2, entry_err = batch:create_entry(category_id, nil, "Test content")
                expect(batch2).to_be_nil()
                expect(entry_err).to_contain("Missing required field")
                expect(entry_err).to_contain("type")
            end)

            it("should fail to create entry with non-existent category", function()
                local project_id, category_id = setup_with_category()

                local batch, batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(batch_err).to_be_nil()

                local batch2, entry_err = batch:create_entry(uuid.v7(), "text", "Test content", consts.CONTENT_TYPE.TEXT_PLAIN, "Test Label")
                expect(entry_err).to_be_nil()

                local result, err = batch2:execute()

                expect(result).to_be_nil()
                expect(err).to_contain("Category does not belong to the specified project")
            end)
        end)

        describe("Complex Batch Operations", function()
            it("should execute multiple operations in a single batch", function()
                clear_mock_messages()

                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, doc_err = batch:create_project("batch_test", "Batch Test Document", { test = true })
                expect(doc_err).to_be_nil()

                local batch3, cat1_err = batch2:create_category("input", "Input Data", { order = 1 })
                expect(cat1_err).to_be_nil()

                local batch4, cat2_err = batch3:create_category("output", "Output Results", { order = 2 })
                expect(cat2_err).to_be_nil()

                local result, err = batch4:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(3)

                register_for_cleanup(result.results[1].project_id)

                local project_id = result.results[1].project_id
                local input_category_id = result.results[2].category_id
                local output_category_id = result.results[3].category_id

                clear_mock_messages()

                -- Add entries to categories
                local entry_batch, entry_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(entry_batch_err).to_be_nil()

                local entry_batch2, entry1_err = entry_batch:create_entry(input_category_id, "text", "Input data", consts.CONTENT_TYPE.TEXT_PLAIN, "Input 1")
                expect(entry1_err).to_be_nil()

                local entry_batch3, entry2_err = entry_batch2:create_entry(input_category_id, "json", json.encode({ data = {1, 2, 3} }), consts.CONTENT_TYPE.APPLICATION_JSON, "Input 2")
                expect(entry2_err).to_be_nil()

                local entry_batch4, entry3_err = entry_batch3:create_entry(output_category_id, "result", json.encode({ result = 42 }), consts.CONTENT_TYPE.APPLICATION_JSON, "Result 1")
                expect(entry3_err).to_be_nil()

                local entry_result, entry_err = entry_batch4:execute()

                expect(entry_err).to_be_nil()
                expect(entry_result.changes_made).to_be_true()
                expect(#entry_result.results).to_equal(3)

                -- Check database state
                local db = get_test_db()

                local doc_rows, doc_err = db:query("SELECT * FROM drafling_projects WHERE project_id = ?", { project_id })
                expect(doc_err).to_be_nil()
                expect(#doc_rows).to_equal(1)

                local cat_rows, cat_err = db:query("SELECT * FROM drafling_categories WHERE project_id = ? ORDER BY name", { project_id })
                expect(cat_err).to_be_nil()
                expect(#cat_rows).to_equal(2)

                local entry_rows, entry_err = db:query("SELECT * FROM drafling_entries WHERE project_id = ? ORDER BY created_at", { project_id })
                expect(entry_err).to_be_nil()
                expect(#entry_rows).to_equal(3)

                -- Check publishing - should have 3 entry creation events
                expect(#test_ctx.mock_messages).to_equal(3)
                for _, message in ipairs(test_ctx.mock_messages) do
                    expect(message.payload.event_type).to_equal("entry_created")
                end
            end)

            it("should update multiple entities in a batch", function()
                clear_mock_messages()

                -- Setup initial data
                local setup_batch, setup_batch_err = writer.for_user(test_ctx.test_user_id)
                expect(setup_batch_err).to_be_nil()

                local setup_batch2, setup_doc_err = setup_batch:create_project("update_batch_test", "Update Batch Test")
                expect(setup_doc_err).to_be_nil()

                local setup_batch3, setup_cat_err = setup_batch2:create_category("notes", "Notes")
                expect(setup_cat_err).to_be_nil()

                local setup_result, setup_err = setup_batch3:execute()
                expect(setup_err).to_be_nil()

                register_for_cleanup(setup_result.results[1].project_id)

                local project_id = setup_result.results[1].project_id
                local category_id = setup_result.results[2].category_id

                local entry_batch, entry_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(entry_batch_err).to_be_nil()

                local entry_batch2, entry_create_err = entry_batch:create_entry(category_id, "text", "Original content", consts.CONTENT_TYPE.TEXT_PLAIN, "Original Label")
                expect(entry_create_err).to_be_nil()

                local entry_setup, entry_setup_err = entry_batch2:execute()
                expect(entry_setup_err).to_be_nil()

                local entry_id = entry_setup.results[1].entry_id

                clear_mock_messages()

                -- Update multiple entities
                local update_batch, update_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(update_batch_err).to_be_nil()

                local update_batch2, update_doc_err = update_batch:update_project({ title = "Updated Batch Test", status = consts.STATUS.ACTIVE })
                expect(update_doc_err).to_be_nil()

                local update_batch3, update_cat_err = update_batch2:update_category(category_id, { display_name = "Updated Notes", metadata = { updated = true } })
                expect(update_cat_err).to_be_nil()

                local update_batch4, update_entry_err = update_batch3:update_entry(entry_id, { content = "Updated content", title = "Updated Label", status = consts.STATUS.PUBLISHED })
                expect(update_entry_err).to_be_nil()

                local result, err = update_batch4:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(3)

                -- Verify updates
                local db = get_test_db()

                local doc_rows, doc_err = db:query("SELECT * FROM drafling_projects WHERE project_id = ?", { project_id })
                expect(doc_err).to_be_nil()
                expect(doc_rows[1].title).to_equal("Updated Batch Test")
                expect(doc_rows[1].status).to_equal(consts.STATUS.ACTIVE)

                local cat_rows, cat_err = db:query("SELECT * FROM drafling_categories WHERE category_id = ?", { category_id })
                expect(cat_err).to_be_nil()
                expect(cat_rows[1].display_name).to_equal("Updated Notes")

                local entry_rows, entry_err = db:query("SELECT * FROM drafling_entries WHERE entry_id = ?", { entry_id })
                expect(entry_err).to_be_nil()
                expect(entry_rows[1].content).to_equal("Updated content")
                expect(entry_rows[1].status).to_equal(consts.STATUS.PUBLISHED)

                -- Check publishing - should have 3 update events
                expect(#test_ctx.mock_messages).to_equal(3)
                local event_types = {}
                for _, message in ipairs(test_ctx.mock_messages) do
                    table.insert(event_types, message.payload.event_type)
                end

                local has_doc_updated = false
                local has_cat_updated = false
                local has_entry_updated = false
                for _, event_type in ipairs(event_types) do
                    if event_type == "project_updated" then has_doc_updated = true end
                    if event_type == "category_updated" then has_cat_updated = true end
                    if event_type == "entry_updated" then has_entry_updated = true end
                end

                expect(has_doc_updated).to_be_true()
                expect(has_cat_updated).to_be_true()
                expect(has_entry_updated).to_be_true()
            end)
        end)

        describe("Transaction Management", function()
            it("should handle transaction rollback on failure", function()
                clear_mock_messages()

                local project_id = uuid.v7()
                register_for_cleanup(project_id)

                -- This should fail because we're trying to create an entry with a non-existent category
                local batch, batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(batch_err).to_be_nil()

                local batch2, doc_err = batch:create_project("transaction_test", "Transaction Test")
                expect(doc_err).to_be_nil()

                local batch3, entry_err = batch2:create_entry(uuid.v7(), "text", "Should fail", consts.CONTENT_TYPE.TEXT_PLAIN, "Fail")
                expect(entry_err).to_be_nil()

                local result, err = batch3:execute()

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()

                -- Check that nothing was created
                local db = get_test_db()
                local doc_rows, doc_err = db:query("SELECT COUNT(*) as count FROM drafling_projects WHERE project_id = ?", { project_id })
                expect(doc_err).to_be_nil()
                expect(doc_rows[1].count).to_equal(0)

               -- No publishing should have occurred
                expect(#test_ctx.mock_messages).to_equal(0)
            end)

            it("should support tx_execute with external transaction", function()
                clear_mock_messages()

                local db = get_test_db()
                local tx, tx_err = db:begin()
                expect(tx_err).to_be_nil()

                local project_id = uuid.v7()
                register_for_cleanup(project_id)

                local commands = {
                    {
                        type = consts.OPERATION_TYPE.CREATE_PROJECT,
                        payload = {
                            project_id = project_id,
                            user_id = test_ctx.test_user_id,
                            project_type = "tx_test",
                            title = "Transaction Test"
                        }
                    },
                    {
                        type = consts.OPERATION_TYPE.CREATE_CATEGORY,
                        payload = {
                            project_id = project_id,
                            name = "test_category",
                            display_name = "Test Category"
                        }
                    }
                }

                local result, err = writer.tx_execute(tx, test_ctx.test_user_id, project_id, commands, { publish = false })

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                expect(#result.results).to_equal(2)

                -- Commit the transaction
                tx:commit()

                -- Verify data was created
                local doc_rows, doc_err = db:query("SELECT * FROM drafling_projects WHERE project_id = ?", { project_id })
                expect(doc_err).to_be_nil()
                expect(#doc_rows).to_equal(1)

                -- No publishing should have occurred due to publish = false
                expect(#test_ctx.mock_messages).to_equal(0)
            end)
        end)

        describe("Publishing Configuration", function()
            it("should disable publishing when specified", function()
                clear_mock_messages()

                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, doc_err = batch:create_project("no_publish_test", "No Publish Test")
                expect(doc_err).to_be_nil()

                local result, err = batch2:execute({ publish = false })

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                register_for_cleanup(result.results[1].project_id)

                -- No messages should be published
                expect(#test_ctx.mock_messages).to_equal(0)
            end)

            it("should publish by default", function()
                clear_mock_messages()

                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, doc_err = batch:create_project("default_publish_test", "Default Publish Test")
                expect(doc_err).to_be_nil()

                local result, err = batch2:execute()

                expect(err).to_be_nil()
                expect(result.changes_made).to_be_true()
                register_for_cleanup(result.results[1].project_id)

                -- Should have published by default
                expect(#test_ctx.mock_messages).to_equal(1)
                expect(test_ctx.mock_messages[1].payload.event_type).to_equal("project_created")
            end)
        end)

        describe("Error Handling", function()
            it("should handle empty commands gracefully", function()
                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local result, err = batch:execute()
                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.changes_made).to_be_false()
                expect(#result.commands).to_equal(0)
            end)

            it("should fail to create entry with non-existent category", function()
                -- Create a project but try to create an entry with a non-existent category
                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, doc_err = batch:create_project("validation_test", "Validation Test")
                expect(doc_err).to_be_nil()

                local batch3, entry_err = batch2:create_entry(uuid.v7(), "text", "Should fail", consts.CONTENT_TYPE.TEXT_PLAIN, "Fail")
                expect(entry_err).to_be_nil()

                local result, err = batch3:execute()
                expect(result).to_be_nil()
                expect(err).to_contain("Category does not belong to the specified project")
            end)

            it("should validate required fields in direct API calls", function()
                local result, err = writer.execute(nil, "doc123", {})
                expect(result).to_be_nil()
                expect(err).to_contain("Missing required field")
                expect(err).to_contain("user_id")

                local result2, err2 = writer.execute("user123", nil, {})
                expect(result2).to_be_nil()
                expect(err2).to_contain("Missing required field")
                expect(err2).to_contain("project_id")

                local result3, err3 = writer.execute("user123", "doc123", {})
                expect(result3).to_be_nil()
                expect(err3).to_contain("Commands array cannot be empty")
            end)
        end)

        describe("Publishing Details", function()
            it("should publish correct event data", function()
                clear_mock_messages()

                local batch, batch_err = writer.for_user(test_ctx.test_user_id)
                expect(batch_err).to_be_nil()

                local batch2, doc_err = batch:create_project("publish_detail_test", "Publish Detail Test", { priority = "high" })
                expect(doc_err).to_be_nil()

                local result, err = batch2:execute()

                expect(err).to_be_nil()
                register_for_cleanup(result.results[1].project_id)

                expect(#test_ctx.mock_messages).to_equal(1)

                local message = test_ctx.mock_messages[1]
                expect(message.target_process).to_equal("user." .. test_ctx.test_user_id)
                expect(message.topic).to_equal(consts.TOPIC.PROJECT_PREFIX .. result.results[1].project_id)

                local payload = message.payload
                expect(payload.event_type).to_equal("project_created")
                expect(payload.project_id).to_equal(result.results[1].project_id)
                expect(payload.project_type).to_equal("publish_detail_test")
                expect(payload.title).to_equal("Publish Detail Test")
                expect(payload.updated_at).to_equal("2024-01-01T12:00:00.000Z")
            end)

            it("should publish category and entry events with correct data", function()
                clear_mock_messages()

                -- Setup project and category
                local setup_batch, setup_batch_err = writer.for_user(test_ctx.test_user_id)
                expect(setup_batch_err).to_be_nil()

                local setup_batch2, setup_doc_err = setup_batch:create_project("event_test", "Event Test")
                expect(setup_doc_err).to_be_nil()

                local setup_batch3, setup_cat_err = setup_batch2:create_category("events", "Events Category", { special = true })
                expect(setup_cat_err).to_be_nil()

                local setup_result, setup_err = setup_batch3:execute()
                expect(setup_err).to_be_nil()

                register_for_cleanup(setup_result.results[1].project_id)

                local project_id = setup_result.results[1].project_id
                local category_id = setup_result.results[2].category_id

                clear_mock_messages()

               -- Create entry
                local entry_batch, entry_batch_err = writer.for_project(test_ctx.test_user_id, project_id)
                expect(entry_batch_err).to_be_nil()

                local entry_batch2, entry_create_err = entry_batch:create_entry(category_id, "note", "Test note content", consts.CONTENT_TYPE.TEXT_PLAIN, "Test Note", consts.STATUS.ACTIVE, { important = true })
                expect(entry_create_err).to_be_nil()

                local entry_result, entry_err = entry_batch2:execute()
                expect(entry_err).to_be_nil()

                expect(#test_ctx.mock_messages).to_equal(1)

                local entry_message = test_ctx.mock_messages[1]
                local entry_payload = entry_message.payload

                expect(entry_payload.event_type).to_equal("entry_created")
                expect(entry_payload.project_id).to_equal(project_id)
                expect(entry_payload.entry_id).to_equal(entry_result.results[1].entry_id)
                expect(entry_payload.category_id).to_equal(category_id)
                expect(entry_payload.type).to_equal("note")
                expect(entry_payload.content_type).to_equal(consts.CONTENT_TYPE.TEXT_PLAIN)
                expect(entry_payload.title).to_equal("Test Note")
                expect(entry_payload.status).to_equal(consts.STATUS.ACTIVE)
                expect(entry_payload.updated_at).to_equal("2024-01-01T12:00:00.000Z")
            end)
        end)
    end)
end

return test.run_cases(define_tests)