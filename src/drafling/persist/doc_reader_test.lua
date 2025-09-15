local test = require("test")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local sql = require("sql")
local doc_reader = require("doc_reader")
local consts = require("drafling_consts")

local function define_tests()
    describe("Document Reader", function()
        local test_ctx = {
            cleanup_project_ids = {},
            test_user_id = "reader-user-" .. uuid.v7(),
            test_projects = {},
            test_categories = {},
            test_entries = {},
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

        before_all(function()
            local db = get_test_db()
            local tx, err_tx = db:begin()
            expect(err_tx).to_be_nil()

            local now = time.now()
            local now_ts = now:format(time.RFC3339NANO)

            local docs = {
                {
                    project_id = uuid.v7(),
                    project_type = "typeA",
                    title = "Document A1",
                    status = consts.STATUS.DRAFT,
                    metadata = json.encode({ priority = "high", tags = { "important" } })
                },
                {
                    project_id = uuid.v7(),
                    project_type = "typeA",
                    title = "Document A2",
                    status = consts.STATUS.ACTIVE,
                    metadata = json.encode({ priority = "low" })
                },
                {
                    project_id = uuid.v7(),
                    project_type = "typeB",
                    title = "Document B1",
                    status = consts.STATUS.PUBLISHED,
                    metadata = json.encode({ category = "test" })
                }
            }

            for _, doc in ipairs(docs) do
                tx:execute([[
                    INSERT INTO drafling_projects (project_id, user_id, project_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ]], { doc.project_id, test_ctx.test_user_id, doc.project_type, doc.title, doc.status, doc.metadata, now_ts, now_ts })

                table.insert(test_ctx.test_projects, doc)
                register_for_cleanup(doc.project_id)
            end

            local categories = {
                { category_id = uuid.v7(), project_id = docs[1].project_id, name = "input", display_name = "Input Data", metadata = json.encode({ type = "data" }) },
                { category_id = uuid.v7(), project_id = docs[1].project_id, name = "output", display_name = "Output Results", metadata = json.encode({ type = "results" }) },
                { category_id = uuid.v7(), project_id = docs[2].project_id, name = "notes", display_name = "Notes", metadata = json.encode({}) },
                { category_id = uuid.v7(), project_id = docs[3].project_id, name = "input", display_name = "B Input", metadata = json.encode({}) }
            }

            for _, cat in ipairs(categories) do
                tx:execute([[
                    INSERT INTO drafling_categories (category_id, project_id, name, display_name, metadata, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                ]], { cat.category_id, cat.project_id, cat.name, cat.display_name, cat.metadata, now_ts })

                table.insert(test_ctx.test_categories, cat)
            end

            local entries = {
                { entry_id = uuid.v7(), project_id = docs[1].project_id, category_id = categories[1].category_id, type = "text", content = "Text entry 1", content_type = "text/plain", title = "Label 1", status = "active", metadata = json.encode({ source = "user" }) },
                { entry_id = uuid.v7(), project_id = docs[1].project_id, category_id = categories[2].category_id, type = "result", content = json.encode({ value = 42 }), content_type = "application/json", title = "Result 1", status = "completed", metadata = json.encode({ calculated = true }) },
                { entry_id = uuid.v7(), project_id = docs[2].project_id, category_id = categories[3].category_id, type = "note", content = "Note content", content_type = "text/plain", title = "Note 1", status = "active", metadata = json.encode({}) },
                { entry_id = uuid.v7(), project_id = docs[3].project_id, category_id = categories[4].category_id, type = "text", content = "B doc entry", content_type = "text/plain", title = "B Label", status = "draft", metadata = json.encode({}) }
            }

            for _, entry in ipairs(entries) do
                tx:execute([[
                    INSERT INTO drafling_entries (entry_id, project_id, category_id, type, content, content_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]], { entry.entry_id, entry.project_id, entry.category_id, entry.type, entry.content, entry.content_type, entry.title, entry.status, entry.metadata, now_ts, now_ts })

                table.insert(test_ctx.test_entries, entry)
            end

            tx:commit()
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

        describe("Initialization", function()
            it("should initialize with a user ID", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()
                expect(reader).not_to_be_nil()
            end)

            it("should fail without user ID", function()
                local reader1, err1 = doc_reader.with_user(nil)
                expect(reader1).to_be_nil()
                expect(err1).to_contain("User ID is required")

                local reader2, err2 = doc_reader.with_user("")
                expect(reader2).to_be_nil()
                expect(err2).to_contain("User ID is required")
            end)
        end)

        describe("Basic Query Operations", function()
            it("should return all projects for user", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
                for _, doc in ipairs(results) do
                    expect(doc.user_id).to_equal(test_ctx.test_user_id)
                    expect(doc.metadata).to_be_type("table")
                end
            end)

            it("should count all projects for user", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local count, count_err = reader:count()
                expect(count_err).to_be_nil()
                expect(count).to_equal(3)
            end)

            it("should check existence of projects", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local exists, exists_err = reader:exists()
                expect(exists_err).to_be_nil()
                expect(exists).to_be_true()

                local non_reader, non_err = doc_reader.with_user("non-existent-user")
                expect(non_err).to_be_nil()

                local non_exists, non_exists_err = non_reader:exists()
                expect(non_exists_err).to_be_nil()
                expect(non_exists).to_be_false()
            end)

            it("should return one project", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local doc, doc_err = reader:one()
                expect(doc_err).to_be_nil()

                expect(doc).not_to_be_nil()
                expect(doc.user_id).to_equal(test_ctx.test_user_id)
                expect(doc.metadata).to_be_type("table")
            end)

            it("should return nil when no projects match", function()
                local reader, err = doc_reader.with_user("no-docs-user")
                expect(err).to_be_nil()

                local doc, doc_err = reader:one()
                expect(doc_err).to_be_nil()
                expect(doc).to_be_nil()
            end)
        end)

        describe("Document Filtering", function()
            it("should filter by specific project IDs", function()
                -- Get actual project ID from database
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local all_docs, all_err = reader:all()
                expect(all_err).to_be_nil()
                expect(#all_docs).to_be_greater_than(0)

                local doc_id = all_docs[1].project_id
                local results, query_err = reader:with_projects(doc_id):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(1)
                expect(results[1].project_id).to_equal(doc_id)
            end)

            it("should filter by multiple project IDs", function()
                -- Get actual project IDs from database
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local all_docs, all_err = reader:all()
                expect(all_err).to_be_nil()
                expect(#all_docs).to_be_greater_than_or_equal(2)

                local doc_id1 = all_docs[1].project_id
                local doc_id2 = all_docs[2].project_id
                local results, query_err = reader:with_projects(doc_id1, doc_id2):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(2)
                local found_ids = {}
                for _, doc in ipairs(results) do
                    found_ids[doc.project_id] = true
                end
                expect(found_ids[doc_id1]).to_be_true()
                expect(found_ids[doc_id2]).to_be_true()
            end)

            it("should filter by project type", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_project_types("typeA"):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(2)
                for _, doc in ipairs(results) do
                    expect(doc.project_type).to_equal("typeA")
                end
            end)

            it("should filter by multiple project types", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_project_types("typeA", "typeB"):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
            end)

            it("should filter by project status", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_project_statuses(consts.STATUS.DRAFT):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(1)
                expect(results[1].status).to_equal(consts.STATUS.DRAFT)
            end)

            it("should filter by multiple project statuses", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_project_statuses(consts.STATUS.DRAFT, consts.STATUS.ACTIVE):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(2)
                for _, doc in ipairs(results) do
                    local valid_status = doc.status == consts.STATUS.DRAFT or doc.status == consts.STATUS.ACTIVE
                    expect(valid_status).to_be_true()
                end
            end)

            it("should combine multiple filters", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_project_types("typeA"):with_project_statuses(consts.STATUS.DRAFT):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(1)
                expect(results[1].project_type).to_equal("typeA")
                expect(results[1].status).to_equal(consts.STATUS.DRAFT)
            end)
        end)

        describe("Category and Entry Filtering", function()
            it("should filter by category names", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_categories("input"):include_categories():all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(2)
                for _, doc in ipairs(results) do
                    local has_input = false
                    for _, cat in ipairs(doc.categories) do
                        if cat.name == "input" then
                            has_input = true
                            break
                        end
                    end
                    expect(has_input).to_be_true()
                end
            end)

            it("should filter by entry types", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_entry_types("text"):include_entries():all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(2)
                for _, doc in ipairs(results) do
                    local has_text = false
                    for _, entry in ipairs(doc.entries) do
                        if entry.type == "text" then
                            has_text = true
                            break
                        end
                    end
                    expect(has_text).to_be_true()
                end
            end)

            it("should filter by entry statuses", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_entry_statuses("active"):include_entries():all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(2)
                for _, doc in ipairs(results) do
                    local has_active = false
                    for _, entry in ipairs(doc.entries) do
                        if entry.status == "active" then
                            has_active = true
                            break
                        end
                    end
                    expect(has_active).to_be_true()
                end
            end)
        end)

        describe("Include Operations", function()
            it("should include categories", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:include_categories():all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
                for _, doc in ipairs(results) do
                    expect(doc.categories).to_be_type("table")
                    for _, cat in ipairs(doc.categories) do
                        expect(cat.project_id).to_equal(doc.project_id)
                        expect(cat.metadata).to_be_type("table")
                    end
                end

                local doc_with_cats = nil
                for _, doc in ipairs(results) do
                    if #doc.categories > 0 then
                        doc_with_cats = doc
                        break
                    end
                end
                expect(doc_with_cats).not_to_be_nil()
            end)

            it("should include entries", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:include_entries():all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
                for _, doc in ipairs(results) do
                    expect(doc.entries).to_be_type("table")
                    for _, entry in ipairs(doc.entries) do
                        expect(entry.project_id).to_equal(doc.project_id)
                        expect(entry.metadata).to_be_type("table")
                    end
                end
            end)

            it("should include both categories and entries", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:include_categories():include_entries():all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
                for _, doc in ipairs(results) do
                    expect(doc.categories).to_be_type("table")
                    expect(doc.entries).to_be_type("table")
                end
            end)

            it("should not include categories or entries by default", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
                for _, doc in ipairs(results) do
                    expect(doc.categories).to_be_nil()
                    expect(doc.entries).to_be_nil()
                end
            end)
        end)

        describe("Fetch Options", function()
            it("should exclude metadata when specified", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:fetch_options({ metadata = false }):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
                for _, doc in ipairs(results) do
                    expect(doc.metadata).to_be_nil()
                end
            end)

            it("should exclude content when specified for entries", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:include_entries():fetch_options({ content = false }):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
                for _, doc in ipairs(results) do
                    for _, entry in ipairs(doc.entries) do
                        expect(entry.content).to_be_nil()
                    end
                end
            end)

            it("should handle multiple fetch options", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:include_categories():include_entries():fetch_options({ metadata = false, content = false }):all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(3)
                for _, doc in ipairs(results) do
                    expect(doc.metadata).to_be_nil()
                    for _, entry in ipairs(doc.entries) do
                        expect(entry.content).to_be_nil()
                        expect(entry.metadata).to_be_nil()
                    end
                    for _, cat in ipairs(doc.categories) do
                        expect(cat.metadata).to_be_nil()
                    end
                end
            end)

            it("should ignore invalid fetch options", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:fetch_options(nil):all()
                expect(query_err).to_be_nil()
                expect(#results).to_equal(3)

                local results2, query_err2 = reader:fetch_options("invalid"):all()
                expect(query_err2).to_be_nil()
                expect(#results2).to_equal(3)
            end)
        end)

        describe("Fluent API Immutability", function()
            it("should not modify original reader instance", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local filtered = reader:with_project_types("typeA")
                local with_cats = filtered:include_categories()

                local original_count, original_err = reader:count()
                expect(original_err).to_be_nil()

                local filtered_count, filtered_err = filtered:count()
                expect(filtered_err).to_be_nil()

                local with_cats_count, with_cats_err = with_cats:count()
                expect(with_cats_err).to_be_nil()

                expect(original_count).to_equal(3)
                expect(filtered_count).to_equal(2)
                expect(with_cats_count).to_equal(2)

                local original_docs, original_docs_err = reader:all()
                expect(original_docs_err).to_be_nil()
                expect(original_docs[1].categories).to_be_nil()

                local with_cats_docs, with_cats_docs_err = with_cats:all()
                expect(with_cats_docs_err).to_be_nil()
                expect(with_cats_docs[1].categories).to_be_type("table")
            end)

            it("should allow chaining multiple filters", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local chained_reader = reader:with_project_types("typeA")
                    :with_project_statuses(consts.STATUS.DRAFT, consts.STATUS.ACTIVE)
                    :include_categories()
                    :include_entries()
                    :fetch_options({ metadata = true, content = true })

                local results, query_err = chained_reader:all()
                expect(query_err).to_be_nil()
                expect(#results).to_equal(2)

                for _, doc in ipairs(results) do
                    expect(doc.project_type).to_equal("typeA")
                    local valid_status = doc.status == consts.STATUS.DRAFT or doc.status == consts.STATUS.ACTIVE
                    expect(valid_status).to_be_true()
                    expect(doc.categories).to_be_type("table")
                    expect(doc.entries).to_be_type("table")
                    expect(doc.metadata).to_be_type("table")
                end
            end)
        end)

        describe("Edge Cases", function()
            it("should handle empty results gracefully", function()
                local reader, err = doc_reader.with_user(test_ctx.test_user_id)
                expect(err).to_be_nil()

                local results, query_err = reader:with_project_types("non_existent_type"):all()
                expect(query_err).to_be_nil()
                expect(#results).to_equal(0)

                local count, count_err = reader:with_project_types("non_existent_type"):count()
                expect(count_err).to_be_nil()
                expect(count).to_equal(0)

                local exists, exists_err = reader:with_project_types("non_existent_type"):exists()
                expect(exists_err).to_be_nil()
                expect(exists).to_be_false()

                local one, one_err = reader:with_project_types("non_existent_type"):one()
                expect(one_err).to_be_nil()
                expect(one).to_be_nil()
            end)

            it("should handle projects with no categories or entries", function()
                local empty_doc_user = "empty-doc-user-" .. uuid.v7()
                local db = get_test_db()
                local now_ts = time.now():format(time.RFC3339NANO)

                local empty_doc_id = uuid.v7()
                db:execute([[
                    INSERT INTO drafling_projects (project_id, user_id, project_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ]], { empty_doc_id, empty_doc_user, "empty_type", "Empty Doc", consts.STATUS.DRAFT, "{}", now_ts, now_ts })

                register_for_cleanup(empty_doc_id)

                local reader, err = doc_reader.with_user(empty_doc_user)
                expect(err).to_be_nil()

                local results, query_err = reader:include_categories():include_entries():all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(1)
                expect(results[1].categories).to_be_type("table")
                expect(#results[1].categories).to_equal(0)
                expect(results[1].entries).to_be_type("table")
                expect(#results[1].entries).to_equal(0)
            end)

            it("should handle malformed JSON metadata gracefully", function()
                local malformed_user = "malformed-user-" .. uuid.v7()
                local db = get_test_db()
                local now_ts = time.now():format(time.RFC3339NANO)

                local malformed_doc_id = uuid.v7()
                db:execute([[
                    INSERT INTO drafling_projects (project_id, user_id, project_type, title, status, metadata, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ]], { malformed_doc_id, malformed_user, "malformed_type", "Malformed Doc", consts.STATUS.DRAFT, '{"invalid":json}', now_ts, now_ts })

                register_for_cleanup(malformed_doc_id)

                local reader, err = doc_reader.with_user(malformed_user)
                expect(err).to_be_nil()

                local results, query_err = reader:all()
                expect(query_err).to_be_nil()

                expect(#results).to_equal(1)
                expect(results[1].metadata).to_be_type("table")
                expect(next(results[1].metadata)).to_be_nil()
            end)
        end)
    end)
end

return test.run_cases(define_tests)