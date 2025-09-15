local test = require("test")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local sql = require("sql")
local doc_repo = require("doc_repo")
local consts = require("drafling_consts")

local function define_tests()
    describe("Document Repository", function()
        local test_ctx = {
            cleanup_project_ids = {},
            test_user_id = "test-user-" .. uuid.v7(),
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

        describe("Document CRUD Operations", function()
            it("should create a project with minimal fields", function()
                local doc, err = doc_repo.create(test_ctx.test_user_id, "test_type", "Test Document")

                expect(err).to_be_nil()
                expect(doc).not_to_be_nil()
                expect(doc.project_id).not_to_be_nil()
                expect(doc.user_id).to_equal(test_ctx.test_user_id)
                expect(doc.project_type).to_equal("test_type")
                expect(doc.title).to_equal("Test Document")
                expect(doc.status).to_equal(consts.STATUS.DRAFT)
                expect(doc.metadata).to_be_type("table")
                expect(next(doc.metadata)).to_be_nil()

                register_for_cleanup(doc.project_id)
            end)

            it("should create a project with metadata as table", function()
                local metadata = { source = "test", priority = "high", tags = { "important", "draft" } }
                local doc, err = doc_repo.create(test_ctx.test_user_id, "metadata_type", "Metadata Test", metadata)

                expect(err).to_be_nil()
                expect(doc).not_to_be_nil()
                expect(doc.metadata.source).to_equal("test")
                expect(doc.metadata.priority).to_equal("high")
                expect(doc.metadata.tags).to_be_type("table")
                expect(#doc.metadata.tags).to_equal(2)

                register_for_cleanup(doc.project_id)
            end)

            it("should fail to create project without required fields", function()
                local _, err1 = doc_repo.create(nil, "test_type", "Test")
                expect(err1).to_contain("User ID is required")

                local _, err2 = doc_repo.create(test_ctx.test_user_id, nil, "Test")
                expect(err2).to_contain("Document type is required")

                local _, err3 = doc_repo.create("", "test_type", "Test")
                expect(err3).to_contain("User ID is required")

                local _, err4 = doc_repo.create(test_ctx.test_user_id, "", "Test")
                expect(err4).to_contain("Document type is required")
            end)

            it("should get a project by ID", function()
                local created_doc, create_err = doc_repo.create(test_ctx.test_user_id, "get_test", "Get Test", { test = true })
                expect(create_err).to_be_nil()
                register_for_cleanup(created_doc.project_id)

                local doc, err = doc_repo.get(created_doc.project_id, test_ctx.test_user_id)

                expect(err).to_be_nil()
                expect(doc).not_to_be_nil()
                expect(doc.project_id).to_equal(created_doc.project_id)
                expect(doc.title).to_equal("Get Test")
                expect(doc.metadata.test).to_be_true()
            end)

            it("should get a project by ID without user filter", function()
                local created_doc, create_err = doc_repo.create(test_ctx.test_user_id, "get_no_user", "No User Filter")
                expect(create_err).to_be_nil()
                register_for_cleanup(created_doc.project_id)

                local doc, err = doc_repo.get(created_doc.project_id)

                expect(err).to_be_nil()
                expect(doc).not_to_be_nil()
                expect(doc.project_id).to_equal(created_doc.project_id)
            end)

            it("should return error for non-existent project", function()
                local _, err = doc_repo.get(uuid.v7(), test_ctx.test_user_id)
                expect(err).to_contain("Document not found")
            end)

            it("should return error for empty project ID", function()
                local _, err1 = doc_repo.get(nil, test_ctx.test_user_id)
                expect(err1).to_contain("Document ID is required")

                local _, err2 = doc_repo.get("", test_ctx.test_user_id)
                expect(err2).to_contain("Document ID is required")
            end)

            it("should update project title", function()
                local created_doc, create_err = doc_repo.create(test_ctx.test_user_id, "update_test", "Original Title")
                expect(create_err).to_be_nil()
                register_for_cleanup(created_doc.project_id)

                local result, err = doc_repo.update(created_doc.project_id, test_ctx.test_user_id, { title = "Updated Title" })

                expect(err).to_be_nil()
                expect(result.rows_affected).to_equal(1)

                local updated_doc, get_err = doc_repo.get(created_doc.project_id, test_ctx.test_user_id)
                expect(get_err).to_be_nil()
                expect(updated_doc.title).to_equal("Updated Title")
            end)

            it("should update project status", function()
                local created_doc, create_err = doc_repo.create(test_ctx.test_user_id, "status_test", "Status Test")
                expect(create_err).to_be_nil()
                register_for_cleanup(created_doc.project_id)

                local result, err = doc_repo.update(created_doc.project_id, test_ctx.test_user_id, { status = consts.STATUS.ACTIVE })

                expect(err).to_be_nil()
                expect(result.rows_affected).to_equal(1)

                local updated_doc, get_err = doc_repo.get(created_doc.project_id, test_ctx.test_user_id)
                expect(get_err).to_be_nil()
                expect(updated_doc.status).to_equal(consts.STATUS.ACTIVE)
            end)

            it("should update project metadata", function()
                local created_doc, create_err = doc_repo.create(test_ctx.test_user_id, "meta_test", "Meta Test", { original = true })
                expect(create_err).to_be_nil()
                register_for_cleanup(created_doc.project_id)

                local new_metadata = { updated = true, version = 2, features = { "new", "improved" } }
                local result, err = doc_repo.update(created_doc.project_id, test_ctx.test_user_id, { metadata = new_metadata })

                expect(err).to_be_nil()
                expect(result.rows_affected).to_equal(1)

                local updated_doc, get_err = doc_repo.get(created_doc.project_id, test_ctx.test_user_id)
                expect(get_err).to_be_nil()
                expect(updated_doc.metadata.updated).to_be_true()
                expect(updated_doc.metadata.version).to_equal(2)
                expect(#updated_doc.metadata.features).to_equal(2)
            end)

            it("should update multiple fields at once", function()
                local created_doc, create_err = doc_repo.create(test_ctx.test_user_id, "multi_test", "Multi Test")
                expect(create_err).to_be_nil()
                register_for_cleanup(created_doc.project_id)

                local updates = {
                    title = "Multi Updated",
                    status = consts.STATUS.PUBLISHED,
                    metadata = { multi_update = true, timestamp = "2024-01-01" }
                }
                local result, err = doc_repo.update(created_doc.project_id, test_ctx.test_user_id, updates)

                expect(err).to_be_nil()
                expect(result.rows_affected).to_equal(1)

                local updated_doc, get_err = doc_repo.get(created_doc.project_id, test_ctx.test_user_id)
                expect(get_err).to_be_nil()
                expect(updated_doc.title).to_equal("Multi Updated")
                expect(updated_doc.status).to_equal(consts.STATUS.PUBLISHED)
                expect(updated_doc.metadata.multi_update).to_be_true()
            end)

            it("should fail update with invalid parameters", function()
                local created_doc, create_err = doc_repo.create(test_ctx.test_user_id, "fail_test", "Fail Test")
                expect(create_err).to_be_nil()
                register_for_cleanup(created_doc.project_id)

                local _, err1 = doc_repo.update(nil, test_ctx.test_user_id, { title = "New" })
                expect(err1).to_contain("Document ID is required")

                local _, err2 = doc_repo.update(created_doc.project_id, nil, { title = "New" })
                expect(err2).to_contain("User ID is required")

                local _, err3 = doc_repo.update(created_doc.project_id, test_ctx.test_user_id, nil)
                expect(err3).to_contain("Updates must be a table")

                local _, err4 = doc_repo.update(created_doc.project_id, test_ctx.test_user_id, {})
                expect(err4).to_contain("No valid fields to update")
            end)

            it("should return error for updating non-existent project", function()
                local _, err = doc_repo.update(uuid.v7(), test_ctx.test_user_id, { title = "Non-existent" })
                expect(err).to_contain("Document not found or no access")
            end)

            it("should delete a project", function()
                local created_doc, create_err = doc_repo.create(test_ctx.test_user_id, "delete_test", "Delete Test")
                expect(create_err).to_be_nil()

                local result, err = doc_repo.delete(created_doc.project_id, test_ctx.test_user_id)

                expect(err).to_be_nil()
                expect(result.rows_affected).to_equal(1)

                local _, get_err = doc_repo.get(created_doc.project_id, test_ctx.test_user_id)
                expect(get_err).to_contain("Document not found")
            end)

            it("should fail delete with invalid parameters", function()
                local _, err1 = doc_repo.delete(nil, test_ctx.test_user_id)
                expect(err1).to_contain("Document ID is required")

                local _, err2 = doc_repo.delete(uuid.v7(), nil)
                expect(err2).to_contain("User ID is required")
            end)

            it("should return error for deleting non-existent project", function()
                local _, err = doc_repo.delete(uuid.v7(), test_ctx.test_user_id)
                expect(err).to_contain("Document not found or no access")
            end)
        end)

        describe("Document Listing", function()
            local list_test_user = "list-user-" .. uuid.v7()
            local list_test_docs = {}

            before_all(function()
                local test_docs = {
                    { type = "typeA", title = "Doc A1", status = consts.STATUS.DRAFT },
                    { type = "typeA", title = "Doc A2", status = consts.STATUS.ACTIVE },
                    { type = "typeB", title = "Doc B1", status = consts.STATUS.DRAFT },
                    { type = "typeB", title = "Doc B2", status = consts.STATUS.PUBLISHED },
                    { type = "typeC", title = "Doc C1", status = consts.STATUS.ARCHIVED }
                }

                for _, spec in ipairs(test_docs) do
                    local doc, err = doc_repo.create(list_test_user, spec.type, spec.title, { test = "list" })
                    expect(err).to_be_nil()
                    doc.status = spec.status

                    local _, update_err = doc_repo.update(doc.project_id, list_test_user, { status = spec.status })
                    expect(update_err).to_be_nil()

                    table.insert(list_test_docs, doc)
                    register_for_cleanup(doc.project_id)
                end
            end)

            it("should list all projects for user", function()
                local docs, err = doc_repo.list_by_user(list_test_user)

                expect(err).to_be_nil()
                expect(#docs).to_equal(5)

                for _, doc in ipairs(docs) do
                    expect(doc.user_id).to_equal(list_test_user)
                    expect(doc.metadata.test).to_equal("list")
                end
            end)

            it("should filter by project type", function()
                local docs, err = doc_repo.list_by_user(list_test_user, { project_type = "typeA" })

                expect(err).to_be_nil()
                expect(#docs).to_equal(2)

                for _, doc in ipairs(docs) do
                    expect(doc.project_type).to_equal("typeA")
                end
            end)

            it("should filter by status", function()
                local docs, err = doc_repo.list_by_user(list_test_user, { status = consts.STATUS.DRAFT })

                expect(err).to_be_nil()
                expect(#docs).to_equal(2)

                for _, doc in ipairs(docs) do
                    expect(doc.status).to_equal(consts.STATUS.DRAFT)
                end
            end)

            it("should order by created date (default)", function()
                local docs, err = doc_repo.list_by_user(list_test_user)

                expect(err).to_be_nil()
                expect(#docs).to_equal(5)

                for i = 2, #docs do
                    expect(docs[i].created_at <= docs[i-1].created_at).to_be_true()
                end
            end)

            it("should order by updated date", function()
                local docs, err = doc_repo.list_by_user(list_test_user, { order_by = "updated" })

                expect(err).to_be_nil()
                expect(#docs).to_equal(5)

                for i = 2, #docs do
                    expect(docs[i].updated_at <= docs[i-1].updated_at).to_be_true()
                end
            end)

            it("should order by title", function()
                local docs, err = doc_repo.list_by_user(list_test_user, { order_by = "title" })

                expect(err).to_be_nil()
                expect(#docs).to_equal(5)

                for i = 2, #docs do
                    expect(docs[i].title >= docs[i-1].title).to_be_true()
                end
            end)

            it("should apply limit", function()
                local docs, err = doc_repo.list_by_user(list_test_user, { limit = 3 })

                expect(err).to_be_nil()
                expect(#docs).to_equal(3)
            end)

            it("should apply offset", function()
                local all_docs, _ = doc_repo.list_by_user(list_test_user)
                local offset_docs, err = doc_repo.list_by_user(list_test_user, { limit = 2, offset = 2 })

                expect(err).to_be_nil()
                expect(#offset_docs).to_equal(2)
                expect(offset_docs[1].project_id).to_equal(all_docs[3].project_id)
            end)

            it("should return empty list for non-existent user", function()
                local docs, err = doc_repo.list_by_user("non-existent-user")

                expect(err).to_be_nil()
                expect(#docs).to_equal(0)
            end)

            it("should fail with invalid user ID", function()
                local _, err1 = doc_repo.list_by_user(nil)
                expect(err1).to_contain("User ID is required")

                local _, err2 = doc_repo.list_by_user("")
                expect(err2).to_contain("User ID is required")
            end)
        end)

        describe("Category Operations", function()
            local cat_test_user = "cat-user-" .. uuid.v7()
            local cat_test_doc_id

            before_all(function()
                local doc, err = doc_repo.create(cat_test_user, "category_test", "Category Test Doc")
                expect(err).to_be_nil()
                cat_test_doc_id = doc.project_id
                register_for_cleanup(cat_test_doc_id)
            end)

            it("should create categories for project", function()
                local categories = {
                    { name = "input", display_name = "Input Data" },
                    { name = "output", display_name = "Output Results", metadata = { type = "results" } },
                    { name = "notes" }
                }

                local created_cats, err = doc_repo.create_categories(cat_test_doc_id, categories)

                expect(err).to_be_nil()
                expect(#created_cats).to_equal(3)

                expect(created_cats[1].name).to_equal("input")
                expect(created_cats[1].display_name).to_equal("Input Data")
                expect(created_cats[1].project_id).to_equal(cat_test_doc_id)

                expect(created_cats[2].metadata.type).to_equal("results")
                expect(created_cats[3].name).to_equal("notes")
                expect(created_cats[3].display_name).to_be_nil()
            end)

            it("should get categories for project", function()
                local categories, err = doc_repo.get_categories(cat_test_doc_id)

                expect(err).to_be_nil()
                expect(#categories).to_equal(3)

                local names = {}
                for _, cat in ipairs(categories) do
                    names[cat.name] = true
                    expect(cat.project_id).to_equal(cat_test_doc_id)
                    expect(cat.metadata).to_be_type("table")
                end

                expect(names["input"]).to_be_true()
                expect(names["output"]).to_be_true()
                expect(names["notes"]).to_be_true()
            end)

            it("should fail to create categories without required fields", function()
                local _, err1 = doc_repo.create_categories(nil, { { name = "test" } })
                expect(err1).to_contain("Document ID is required")

                local _, err2 = doc_repo.create_categories(cat_test_doc_id, nil)
                expect(err2).to_contain("Categories array is required")

                local _, err3 = doc_repo.create_categories(cat_test_doc_id, {})
                expect(err3).to_contain("Categories array is required")

                local _, err4 = doc_repo.create_categories(cat_test_doc_id, { {} })
                expect(err4).to_contain("Category name is required")
            end)

            it("should handle empty categories list for get", function()
                local empty_doc, create_err = doc_repo.create(cat_test_user, "empty_cat", "Empty Categories")
                expect(create_err).to_be_nil()
                register_for_cleanup(empty_doc.project_id)

                local categories, err = doc_repo.get_categories(empty_doc.project_id)

                expect(err).to_be_nil()
                expect(#categories).to_equal(0)
            end)

            it("should fail get categories with invalid project ID", function()
                local _, err1 = doc_repo.get_categories(nil)
                expect(err1).to_contain("Document ID is required")

                local _, err2 = doc_repo.get_categories("")
                expect(err2).to_contain("Document ID is required")
            end)
        end)

        describe("Analytics Operations", function()
            local analytics_user = "analytics-user-" .. uuid.v7()

            before_all(function()
                local db = get_test_db()
                local tx, err_tx = db:begin()
                expect(err_tx).to_be_nil()

                local now_ts = time.now():format(time.RFC3339NANO)

                local doc1_id = uuid.v7()
                local doc2_id = uuid.v7()
                register_for_cleanup(doc1_id)
                register_for_cleanup(doc2_id)

                tx:execute([[
                    INSERT INTO drafling_projects (project_id, user_id, project_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ]], { doc1_id, analytics_user, "analytics_doc", "Analytics Doc 1", consts.STATUS.ACTIVE, "{}", now_ts, now_ts })

                tx:execute([[
                    INSERT INTO drafling_projects (project_id, user_id, project_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ]], { doc2_id, analytics_user, "analytics_doc", "Analytics Doc 2", consts.STATUS.DRAFT, "{}", now_ts, now_ts })

                local cat1_id = uuid.v7()
                local cat2_id = uuid.v7()
                local cat3_id = uuid.v7()

                tx:execute([[
                    INSERT INTO drafling_categories (category_id, project_id, name, display_name, metadata, created_at)
                    VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?)
                ]], { cat1_id, doc1_id, "input", "Input", "{}", now_ts,
                     cat2_id, doc1_id, "output", "Output", "{}", now_ts,
                     cat3_id, doc2_id, "input", "Input", "{}", now_ts })

                tx:execute([[
                    INSERT INTO drafling_entries (entry_id, project_id, category_id, type, content, content_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]], { uuid.v7(), doc1_id, cat1_id, "text", "Entry 1", "text/plain", "Label 1", "active", "{}", now_ts, now_ts,
                     uuid.v7(), doc1_id, cat2_id, "result", "Entry 2", "application/json", "Label 2", "active", "{}", now_ts, now_ts })

                tx:commit()
            end)

            it("should get unique categories for user", function()
                local categories, err = doc_repo.get_unique_categories(analytics_user)

                expect(err).to_be_nil()
                expect(#categories).to_equal(2)
                expect(categories[1]).to_equal("input")
                expect(categories[2]).to_equal("output")
            end)

            it("should get unique entry types for user", function()
                local types, err = doc_repo.get_unique_entry_types(analytics_user)

                expect(err).to_be_nil()
                expect(#types).to_equal(2)

                local type_set = {}
                for _, t in ipairs(types) do
                    type_set[t] = true
                end
                expect(type_set["text"]).to_be_true()
                expect(type_set["result"]).to_be_true()
            end)

            it("should get user statistics", function()
                local stats, err = doc_repo.get_user_stats(analytics_user)

                expect(err).to_be_nil()
                expect(stats.projects_by_type_status).to_be_type("table")
                expect(stats.entries_by_type).to_be_type("table")

                local doc_count = 0
                for _, row in ipairs(stats.projects_by_type_status) do
                    doc_count = doc_count + row.count
                end
                expect(doc_count).to_equal(2)

                local entry_count = 0
                for _, row in ipairs(stats.entries_by_type) do
                    entry_count = entry_count + row.count
                end
                expect(entry_count).to_equal(2)
            end)

            it("should fail analytics with invalid user ID", function()
                local _, err1 = doc_repo.get_unique_categories(nil)
                expect(err1).to_contain("User ID is required")

                local _, err2 = doc_repo.get_unique_entry_types("")
                expect(err2).to_contain("User ID is required")

                local _, err3 = doc_repo.get_user_stats(nil)
                expect(err3).to_contain("User ID is required")
            end)

            it("should return empty results for user with no data", function()
                local empty_user = "empty-user-" .. uuid.v7()

                local categories, cat_err = doc_repo.get_unique_categories(empty_user)
                expect(cat_err).to_be_nil()
                expect(#categories).to_equal(0)

                local types, type_err = doc_repo.get_unique_entry_types(empty_user)
                expect(type_err).to_be_nil()
                expect(#types).to_equal(0)

                local stats, stats_err = doc_repo.get_user_stats(empty_user)
                expect(stats_err).to_be_nil()
                expect(#stats.projects_by_type_status).to_equal(0)
                expect(#stats.entries_by_type).to_equal(0)
            end)
        end)
    end)
end

return test.run_cases(define_tests)