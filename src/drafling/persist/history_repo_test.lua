local test = require("test")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local sql = require("sql")
local history_repo = require("history_repo")
local consts = require("drafling_consts")

local function define_tests()
    describe("History Repository", function()
        local test_ctx = {
            test_user_id = "history-user-" .. uuid.v7(),
            test_project_id = nil,
            test_entry_ids = {},
            test_category_id = nil,
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

        local function cleanup_all_test_data()
            if not test_ctx.test_project_id then return end

            local db = get_test_db()
            local tx, err_tx = db:begin()
            if err_tx then
                print("ERROR: Failed to begin cleanup transaction: " .. tostring(err_tx))
                return
            end

            -- Delete in proper order due to foreign key constraints
            tx:execute("DELETE FROM drafling_entry_history WHERE project_id = ?", { test_ctx.test_project_id })
            tx:execute("DELETE FROM drafling_entries WHERE project_id = ?", { test_ctx.test_project_id })
            tx:execute("DELETE FROM drafling_categories WHERE project_id = ?", { test_ctx.test_project_id })
            tx:execute("DELETE FROM drafling_projects WHERE project_id = ?", { test_ctx.test_project_id })

            local commit_err = tx:commit()
            if commit_err then
                tx:rollback()
            end
        end

        before_all(function()
            -- Clean up any existing data first
            cleanup_all_test_data()

            local db = get_test_db()
            local tx, err_tx = db:begin()
            expect(err_tx).to_be_nil()

            local now = time.now()
            local now_ts = now:format(time.RFC3339NANO)

            -- Create test project
            test_ctx.test_project_id = uuid.v7()
            tx:execute([[
                INSERT INTO drafling_projects (project_id, user_id, project_type, title, status, metadata, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ]], { test_ctx.test_project_id, test_ctx.test_user_id, "history_test", "History Test Doc", consts.STATUS.ACTIVE, "{}", now_ts, now_ts })

            -- Create test category
            test_ctx.test_category_id = uuid.v7()
            tx:execute([[
                INSERT INTO drafling_categories (category_id, project_id, name, display_name, metadata, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
            ]], { test_ctx.test_category_id, test_ctx.test_project_id, "test_category", "Test Category", "{}", now_ts })

            -- Create test entries
            local entries = {
                { entry_id = uuid.v7(), type = "text", content = "Initial content", title = "Entry 1" },
                { entry_id = uuid.v7(), type = "note", content = "Note content", title = "Entry 2" },
                { entry_id = uuid.v7(), type = "result", content = json.encode({ value = 42 }), title = "Entry 3" }
            }

            for _, entry in ipairs(entries) do
                tx:execute([[
                    INSERT INTO drafling_entries (entry_id, project_id, category_id, type, content, content_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]], { entry.entry_id, test_ctx.test_project_id, test_ctx.test_category_id, entry.type, entry.content, "text/plain", entry.title, "active", "{}", now_ts, now_ts })

                table.insert(test_ctx.test_entry_ids, entry.entry_id)
            end

            -- Create history records with different timestamps
            local history_records = {
                {
                    history_id = uuid.v7(),
                    entry_id = test_ctx.test_entry_ids[1], -- Entry 1: CREATE
                    operation_type = consts.HISTORY_OPERATION.CREATE,
                    changes = json.encode({ operation = "create", initial_values = { type = "text", content = "Initial content" } }),
                    created_at = now:add(-86400):format(time.RFC3339NANO) -- 1 day ago
                },
                {
                    history_id = uuid.v7(),
                    entry_id = test_ctx.test_entry_ids[1], -- Entry 1: UPDATE 1
                    operation_type = consts.HISTORY_OPERATION.UPDATE,
                    changes = json.encode({ fields_changed = { "content" }, from = { content = "Initial content" }, to = { content = "Updated content" } }),
                    created_at = now:add(-43200):format(time.RFC3339NANO) -- 12 hours ago
                },
                {
                    history_id = uuid.v7(),
                    entry_id = test_ctx.test_entry_ids[2], -- Entry 2: CREATE
                    operation_type = consts.HISTORY_OPERATION.CREATE,
                    changes = json.encode({ operation = "create", initial_values = { type = "note", content = "Note content" } }),
                    created_at = now:add(-21600):format(time.RFC3339NANO) -- 6 hours ago
                },
                {
                    history_id = uuid.v7(),
                    entry_id = test_ctx.test_entry_ids[1], -- Entry 1: UPDATE 2
                    operation_type = consts.HISTORY_OPERATION.UPDATE,
                    changes = json.encode({ fields_changed = { "title" }, from = { title = "Entry 1" }, to = { title = "Updated Entry 1" } }),
                    created_at = now:add(-3600):format(time.RFC3339NANO) -- 1 hour ago
                },
                {
                    history_id = uuid.v7(),
                    entry_id = test_ctx.test_entry_ids[3], -- Entry 3: CREATE
                    operation_type = consts.HISTORY_OPERATION.CREATE,
                    changes = json.encode({ operation = "create", initial_values = { type = "result", content = '{"value":42}' } }),
                    created_at = now_ts -- now
                }
            }

            for _, history in ipairs(history_records) do
                tx:execute([[
                    INSERT INTO drafling_entry_history (history_id, entry_id, project_id, operation_type, changes, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                ]], { history.history_id, history.entry_id, test_ctx.test_project_id, history.operation_type, history.changes, history.created_at })
            end

            tx:commit()
        end)

        after_all(function()
            cleanup_all_test_data()
            if test_ctx.db then
                test_ctx.db:release()
                test_ctx.db = nil
            end
        end)

        describe("Entry History Operations", function()
            it("should get history for a specific entry", function()
                local entry_id = test_ctx.test_entry_ids[1]
                local history, err = history_repo.get_entry_history(entry_id)

                expect(err).to_be_nil()
                expect(#history).to_equal(3) -- CREATE + UPDATE + UPDATE for entry 1

                -- Verify all records belong to the correct entry
                for _, record in ipairs(history) do
                    expect(record.entry_id).to_equal(entry_id)
                    expect(record.changes).to_be_type("table")
                    expect(record.project_id).to_equal(test_ctx.test_project_id)
                end

                -- Should be ordered newest first by default
                expect(history[1].operation_type).to_equal(consts.HISTORY_OPERATION.UPDATE)
                expect(history[3].operation_type).to_equal(consts.HISTORY_OPERATION.CREATE)
            end)

            it("should get history with operation type filter", function()
                local entry_id = test_ctx.test_entry_ids[1]
                local history, err = history_repo.get_entry_history(entry_id, { operation_type = consts.HISTORY_OPERATION.UPDATE })

                expect(err).to_be_nil()
                expect(#history).to_equal(2) -- Two UPDATE operations for entry 1

                for _, record in ipairs(history) do
                    expect(record.operation_type).to_equal(consts.HISTORY_OPERATION.UPDATE)
                    expect(record.entry_id).to_equal(entry_id)
                end
            end)

            it("should get history in oldest-first order", function()
                local entry_id = test_ctx.test_entry_ids[1]
                local history, err = history_repo.get_entry_history(entry_id, { order = "oldest" })

                expect(err).to_be_nil()
                expect(#history).to_equal(3)

                -- Verify chronological order
                for i = 2, #history do
                    expect(history[i].created_at >= history[i-1].created_at).to_be_true()
                end

                expect(history[1].operation_type).to_equal(consts.HISTORY_OPERATION.CREATE)
                expect(history[3].operation_type).to_equal(consts.HISTORY_OPERATION.UPDATE)
            end)

            it("should apply limit and offset to entry history", function()
                local entry_id = test_ctx.test_entry_ids[1]

                local limited, err1 = history_repo.get_entry_history(entry_id, { limit = 2 })
                expect(err1).to_be_nil()
                expect(#limited).to_equal(2)

                local offset, err2 = history_repo.get_entry_history(entry_id, { limit = 1, offset = 1 })
                expect(err2).to_be_nil()
                expect(#offset).to_equal(1)

                expect(offset[1].history_id).to_equal(limited[2].history_id)
            end)

            it("should return empty history for entry with no records", function()
                local empty_entry_id = uuid.v7()
                local history, err = history_repo.get_entry_history(empty_entry_id)

                expect(err).to_be_nil()
                expect(#history).to_equal(0)
            end)

            it("should fail with invalid entry ID", function()
                local _, err1 = history_repo.get_entry_history(nil)
                expect(err1).to_contain("Entry ID is required")

                local _, err2 = history_repo.get_entry_history("")
                expect(err2).to_contain("Entry ID is required")
            end)
        end)

        describe("Document History Operations", function()
            it("should get all history for a project", function()
                local history, err = history_repo.get_project_history(test_ctx.test_project_id)

                expect(err).to_be_nil()
                expect(#history).to_equal(5) -- Total of 5 history records across all entries

                for _, record in ipairs(history) do
                    expect(record.project_id).to_equal(test_ctx.test_project_id)
                    expect(record.changes).to_be_type("table")
                end

                -- Should be ordered newest first by default
                for i = 2, #history do
                    expect(history[i].created_at <= history[i-1].created_at).to_be_true()
                end
            end)

            it("should filter project history by operation type", function()
                local history, err = history_repo.get_project_history(test_ctx.test_project_id, { operation_type = consts.HISTORY_OPERATION.CREATE })

                expect(err).to_be_nil()
                expect(#history).to_equal(3) -- Three CREATE operations

                for _, record in ipairs(history) do
                    expect(record.operation_type).to_equal(consts.HISTORY_OPERATION.CREATE)
                end
            end)

            it("should filter project history by specific entries", function()
                local entry_ids = { test_ctx.test_entry_ids[1], test_ctx.test_entry_ids[2] }
                local history, err = history_repo.get_project_history(test_ctx.test_project_id, { entry_ids = entry_ids })

                expect(err).to_be_nil()
                expect(#history).to_equal(4) -- 3 records for entry 1, 1 record for entry 2

                for _, record in ipairs(history) do
                    local valid_entry = false
                    for _, test_entry_id in ipairs(entry_ids) do
                        if record.entry_id == test_entry_id then
                            valid_entry = true
                            break
                        end
                    end
                    expect(valid_entry).to_be_true()
                end
            end)

            it("should get project history in oldest-first order", function()
                local history, err = history_repo.get_project_history(test_ctx.test_project_id, { order = "oldest" })

                expect(err).to_be_nil()
                expect(#history).to_equal(5)

                for i = 2, #history do
                    expect(history[i].created_at >= history[i-1].created_at).to_be_true()
                end
            end)

            it("should apply limit and offset to project history", function()
                local limited, err1 = history_repo.get_project_history(test_ctx.test_project_id, { limit = 3 })
                expect(err1).to_be_nil()
                expect(#limited).to_equal(3)

                local offset, err2 = history_repo.get_project_history(test_ctx.test_project_id, { limit = 2, offset = 2 })
                expect(err2).to_be_nil()
                expect(#offset).to_equal(2)
            end)

            it("should return empty history for project with no records", function()
                local empty_doc_id = uuid.v7()
                local history, err = history_repo.get_project_history(empty_doc_id)

                expect(err).to_be_nil()
                expect(#history).to_equal(0)
            end)

            it("should fail with invalid project ID", function()
                local _, err1 = history_repo.get_project_history(nil)
                expect(err1).to_contain("Document ID is required")

                local _, err2 = history_repo.get_project_history("")
                expect(err2).to_contain("Document ID is required")
            end)
        end)

        describe("History Statistics Operations", function()
            it("should get operation statistics for user", function()
                local stats, err = history_repo.get_user_history_stats(test_ctx.test_user_id)

                expect(err).to_be_nil()
                expect(stats.operations_by_type).to_be_type("table")
                expect(stats.activity_by_date).to_be_type("table")

                local create_count = 0
                local update_count = 0
                for _, row in ipairs(stats.operations_by_type) do
                    if row.operation_type == consts.HISTORY_OPERATION.CREATE then
                        create_count = row.count
                    elseif row.operation_type == consts.HISTORY_OPERATION.UPDATE then
                        update_count = row.count
                    end
                end

                expect(create_count).to_equal(3) -- Three CREATE operations
                expect(update_count).to_equal(2) -- Two UPDATE operations
            end)

            it("should get statistics with date filter", function()
                local yesterday = time.now():add(-86400):format(time.RFC3339)
                local stats, err = history_repo.get_user_history_stats(test_ctx.test_user_id, { since = yesterday })

                expect(err).to_be_nil()
                expect(stats.operations_by_type).to_be_type("table")
                expect(stats.activity_by_date).to_be_type("table")

                local total_count = 0
                for _, row in ipairs(stats.operations_by_type) do
                    total_count = total_count + row.count
                end

                expect(total_count).to_be_greater_than(0)
            end)

            it("should return empty statistics for user with no activity", function()
                local empty_user = "empty-stats-user-" .. uuid.v7()
                local stats, err = history_repo.get_user_history_stats(empty_user)

                expect(err).to_be_nil()
                expect(#stats.operations_by_type).to_equal(0)
                expect(#stats.activity_by_date).to_equal(0)
            end)

            it("should fail with invalid user ID", function()
                local _, err1 = history_repo.get_user_history_stats(nil)
                expect(err1).to_contain("User ID is required")

                local _, err2 = history_repo.get_user_history_stats("")
                expect(err2).to_contain("User ID is required")
            end)
        end)

        describe("Individual History Operations", function()
            it("should get latest history record for entry", function()
                local entry_id = test_ctx.test_entry_ids[1]
                local latest, err = history_repo.get_entry_latest_history(entry_id)

                expect(err).to_be_nil()
                expect(latest).not_to_be_nil()
                expect(latest.entry_id).to_equal(entry_id)
                expect(latest.operation_type).to_equal(consts.HISTORY_OPERATION.UPDATE) -- Most recent should be UPDATE
                expect(latest.changes).to_be_type("table")
                expect(latest.changes.fields_changed).to_be_type("table")
            end)

            it("should return nil for entry with no history", function()
                local empty_entry_id = uuid.v7()
                local latest, err = history_repo.get_entry_latest_history(empty_entry_id)

                expect(err).to_be_nil()
                expect(latest).to_be_nil()
            end)

            it("should check if entry has history", function()
                local entry_id = test_ctx.test_entry_ids[1]
                local has_history, err = history_repo.entry_has_history(entry_id)

                expect(err).to_be_nil()
                expect(has_history).to_be_true()
            end)

            it("should return false for entry with no history", function()
                local empty_entry_id = uuid.v7()
                local has_history, err = history_repo.entry_has_history(empty_entry_id)

                expect(err).to_be_nil()
                expect(has_history).to_be_false()
            end)

            it("should fail latest history with invalid entry ID", function()
                local _, err1 = history_repo.get_entry_latest_history(nil)
                expect(err1).to_contain("Entry ID is required")

                local _, err2 = history_repo.get_entry_latest_history("")
                expect(err2).to_contain("Entry ID is required")
            end)

            it("should fail has_history with invalid entry ID", function()
                local has_history, err1 = history_repo.entry_has_history(nil)
                expect(has_history).to_be_false()
                expect(err1).to_contain("Entry ID is required")

                local has_history2, err2 = history_repo.entry_has_history("")
                expect(has_history2).to_be_false()
                expect(err2).to_contain("Entry ID is required")
            end)
        end)

        describe("JSON Parsing and Edge Cases", function()
            it("should parse changes JSON correctly", function()
                local entry_id = test_ctx.test_entry_ids[1]
                local history, err = history_repo.get_entry_history(entry_id, { operation_type = consts.HISTORY_OPERATION.UPDATE, limit = 1 })

                expect(err).to_be_nil()
                expect(#history).to_equal(1)

                local record = history[1]
                expect(record.changes).to_be_type("table")
                expect(record.changes.fields_changed).to_be_type("table")
                expect(record.changes.from).to_be_type("table")
                expect(record.changes.to).to_be_type("table")
            end)

            it("should handle empty changes gracefully", function()
                local db = get_test_db()
                local now_ts = time.now():format(time.RFC3339NANO)

                -- Create a test entry and history record with empty changes
                local test_entry_id = uuid.v7()
                db:execute([[
                    INSERT INTO drafling_entries (entry_id, project_id, category_id, type, content, content_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]], { test_entry_id, test_ctx.test_project_id, test_ctx.test_category_id, "test", "content", "text/plain", "title", "active", "{}", now_ts, now_ts })

                local empty_history_id = uuid.v7()
                db:execute([[
                    INSERT INTO drafling_entry_history (history_id, entry_id, project_id, operation_type, changes, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                ]], { empty_history_id, test_entry_id, test_ctx.test_project_id, consts.HISTORY_OPERATION.CREATE, nil, now_ts })

                local history, err = history_repo.get_entry_history(test_entry_id)

                expect(err).to_be_nil()
                expect(#history).to_equal(1)
                expect(history[1].changes).to_be_type("table")
                expect(next(history[1].changes)).to_be_nil() -- Should be empty table

                -- Clean up the test entry
                db:execute("DELETE FROM drafling_entry_history WHERE entry_id = ?", { test_entry_id })
                db:execute("DELETE FROM drafling_entries WHERE entry_id = ?", { test_entry_id })
            end)

            it("should handle malformed changes JSON gracefully", function()
                local db = get_test_db()
                local now_ts = time.now():format(time.RFC3339NANO)

                -- Create a test entry and history record with malformed JSON
                local test_entry_id = uuid.v7()
                db:execute([[
                    INSERT INTO drafling_entries (entry_id, project_id, category_id, type, content, content_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]], { test_entry_id, test_ctx.test_project_id, test_ctx.test_category_id, "test", "content", "text/plain", "title", "active", "{}", now_ts, now_ts })

                local malformed_history_id = uuid.v7()
                db:execute([[
                    INSERT INTO drafling_entry_history (history_id, entry_id, project_id, operation_type, changes, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                ]], { malformed_history_id, test_entry_id, test_ctx.test_project_id, consts.HISTORY_OPERATION.CREATE, '{"invalid":json}', now_ts })

                local history, err = history_repo.get_entry_history(test_entry_id)

                expect(err).to_be_nil()
                expect(#history).to_equal(1)
                expect(history[1].changes).to_be_type("table")
                expect(next(history[1].changes)).to_be_nil() -- Should be empty table when JSON parsing fails

                -- Clean up the test entry
                db:execute("DELETE FROM drafling_entry_history WHERE entry_id = ?", { test_entry_id })
                db:execute("DELETE FROM drafling_entries WHERE entry_id = ?", { test_entry_id })
            end)

            it("should handle large result sets with pagination", function()
                local history, err = history_repo.get_project_history(test_ctx.test_project_id, { limit = 1000 })

                expect(err).to_be_nil()
                expect(#history).to_equal(5) -- Should return only the actual records

                -- Test with very small limit
                local small_history, small_err = history_repo.get_project_history(test_ctx.test_project_id, { limit = 1 })
                expect(small_err).to_be_nil()
                expect(#small_history).to_equal(1)
            end)
        end)
    end)
end

return test.run_cases(define_tests)