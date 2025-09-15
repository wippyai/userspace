local test = require("test")
local sql = require("sql")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local reader = require("reader")
local ops = require("ops")
local consts = require("consts")

local function run_tests()
    describe("KB9 Reader", function()
        local test_ctx = {
            kb_id = nil,
            created_nodes = {},
            created_components = {}
        }

        -- Helper to execute operation and commit it
        local function execute_op_with_commit(op_type, payload)
            local db, err = sql.get("app:db")
            if err then error("Failed to get database: " .. err) end

            local tx, err = db:begin()
            if err then
                db:release()
                error("Failed to begin transaction: " .. err)
            end

            local command = {
                type = op_type,
                payload = payload
            }

            local result, err = ops.handlers[op_type](tx, test_ctx.kb_id, uuid.v7(), command)
            if err then
                tx:rollback()
                db:release()
                error("Operation failed: " .. err)
            end

            local ok, err = tx:commit()
            if err then
                db:release()
                error("Failed to commit: " .. err)
            end

            db:release()
            return result
        end

        -- Helper to create and commit a test node
        local function create_committed_node(opts)
            opts = opts or {}
            local node_id = opts.id or uuid.v7()

            local payload = {
                id = node_id,
                parent_id = opts.parent_id,
                node_type = opts.node_type or "test_node",
                content = opts.content or "Test content",
                content_type = opts.content_type or "text/plain",
                value = opts.value,
                metadata = opts.metadata or {test = true}
            }

            local result = execute_op_with_commit(ops.COMMAND_TYPES.CREATE_NODE, payload)
            table.insert(test_ctx.created_nodes, node_id)
            return node_id, result
        end

        -- Helper to clean up all test data
        local function cleanup_test_data()
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
            test_ctx.created_nodes = {}
            test_ctx.created_components = {}

            -- Create the KB component
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

        describe("Initialization", function()
            it("should create reader with valid kb_id", function()
                local reader_instance = reader.for_kb(test_ctx.kb_id)
                expect(reader_instance).not_to_be_nil()
                expect(reader_instance._kb_id).to_equal(test_ctx.kb_id)
            end)

            it("should error with empty kb_id", function()
                local success = pcall(function()
                    reader.for_kb("")
                end)
                expect(success).to_be_false()
            end)

            it("should error with nil kb_id", function()
                local success = pcall(function()
                    reader.for_kb(nil)
                end)
                expect(success).to_be_false()
            end)
        end)

        describe("Path Navigation", function()
            before_each(function()
                -- Create hierarchical structure with committed data
                create_committed_node({
                    id = uuid.v7(),
                    node_type = "root",
                    content = "Root node"
                })

                local parent_id, parent_result = create_committed_node({
                    id = uuid.v7(),
                    node_type = "parent",
                    content = "Parent node"
                })

                -- Create children of the parent
                create_committed_node({
                    id = uuid.v7(),
                    parent_id = parent_id,
                    node_type = "child",
                    content = "Child node 1"
                })

                create_committed_node({
                    id = uuid.v7(),
                    parent_id = parent_id,
                    node_type = "child",
                    content = "Child node 2"
                })

                -- Create a separate root
                create_committed_node({
                    id = uuid.v7(),
                    node_type = "root",
                    content = "Second root"
                })
            end)

            it("should find nodes under path prefix", function()
                local parent_nodes = reader.for_kb(test_ctx.kb_id)
                    :of_type("parent")
                    :all()

                expect(#parent_nodes).to_equal(1)
                local parent = parent_nodes[1]

                local children = reader.for_kb(test_ctx.kb_id)
                    :under(parent.path)
                    :all()

                expect(#children).to_equal(2)
                for _, child in ipairs(children) do
                    expect(child.path:sub(1, #parent.path)).to_equal(parent.path)
                    expect(child.path).not_to_equal(parent.path)
                end
            end)

            it("should find node at exact path", function()
                local parent_nodes = reader.for_kb(test_ctx.kb_id)
                    :of_type("parent")
                    :all()

                expect(#parent_nodes).to_equal(1)
                local parent = parent_nodes[1]

                local result = reader.for_kb(test_ctx.kb_id)
                    :at_path(parent.path)
                    :one()

                expect(result).not_to_be_nil()
                expect(result.path).to_equal(parent.path)
                expect(result.node_type).to_equal("parent")
            end)

            it("should return nil for non-existent path", function()
                local result = reader.for_kb(test_ctx.kb_id)
                    :at_path("99999")
                    :one()

                expect(result).to_be_nil()
            end)
        end)

        describe("Type Filtering", function()
            before_each(function()
                create_committed_node({node_type = "document", content = "Doc 1"})
                create_committed_node({node_type = "document", content = "Doc 2"})
                create_committed_node({node_type = "folder", content = "Folder 1"})
                create_committed_node({node_type = "image", content = "Image 1"})
            end)

            it("should filter by single type", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :of_type("document")
                    :all()

                expect(#results).to_equal(2)
                for _, node in ipairs(results) do
                    expect(node.node_type).to_equal("document")
                end
            end)

            it("should filter by multiple types", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :of_types("document", "image")
                    :all()

                expect(#results).to_equal(3) -- 2 documents + 1 image
            end)

            it("should handle array argument for of_types", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :of_types({"folder", "image"})
                    :all()

                expect(#results).to_equal(2)
            end)
        end)

        describe("Parent/Child Relationships", function()
            local parent_id, child1_id, child2_id

            before_each(function()
                parent_id = create_committed_node({
                    node_type = "parent",
                    content = "Parent node"
                })

                child1_id = create_committed_node({
                    parent_id = parent_id,
                    node_type = "child",
                    content = "Child 1"
                })

                child2_id = create_committed_node({
                    parent_id = parent_id,
                    node_type = "child",
                    content = "Child 2"
                })

                -- Create an orphan node (no parent)
                create_committed_node({
                    node_type = "orphan",
                    content = "Orphan node"
                })
            end)

            it("should find children of node", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :children_of(parent_id)
                    :all()

                expect(#results).to_equal(2)
                for _, node in ipairs(results) do
                    expect(node.parent_id).to_equal(parent_id)
                end
            end)

            it("should find nodes with specific parent", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :with_parent(parent_id)
                    :all()

                expect(#results).to_equal(2)
            end)

            it("should return empty for childless node", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :children_of(child1_id)
                    :all()

                expect(#results).to_equal(0)
            end)
        end)

        describe("Text Search", function()
            before_each(function()
                create_committed_node({
                    content = "Authentication guide for OAuth implementation",
                    node_type = "guide"
                })
                create_committed_node({
                    content = "Guide to implement secure authentication mechanisms",
                    node_type = "tutorial"
                })
                create_committed_node({
                    content = "Database migration and schema updates tutorial",
                    node_type = "tutorial"
                })
                create_committed_node({
                    content = "Authentication API reference documentation",
                    node_type = "api_doc"
                })
                create_committed_node({
                    content = "OAuth 2.0 flow examples and best practices",
                    node_type = "example"
                })
            end)

            it("should find nodes by text search", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :search("authentication")
                    :all()

                expect(#results).to_be_greater_than(1)
                for _, node in ipairs(results) do
                    local content_lower = string.lower(node.content or "")
                    expect(content_lower:find("authentication")).not_to_be_nil()
                end
            end)

            it("should combine text search with type filter", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :search("authentication")
                    :of_type("api_doc")
                    :all()

                expect(#results).to_equal(1)
                expect(results[1].node_type).to_equal("api_doc")
            end)

            it("should find nodes with partial matches", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :search("OAuth")
                    :all()

                expect(#results).to_be_greater_than(0)
                for _, node in ipairs(results) do
                    local content_lower = string.lower(node.content or "")
                    expect(content_lower:find("oauth")).not_to_be_nil()
                end
            end)

            it("should handle search with no results", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :search("nonexistent_term_xyz")
                    :all()

                expect(#results).to_equal(0)
            end)
        end)

        describe("Hybrid Search and Filtering", function()
            before_each(function()
                -- Create a complex knowledge structure
                local category_id = create_committed_node({
                    node_type = "category",
                    content = "Security best practices"
                })

                local doc1_id = create_committed_node({
                    parent_id = category_id,
                    node_type = "document",
                    content = "OAuth 2.0 authentication security guide"
                })

                local doc2_id = create_committed_node({
                    parent_id = category_id,
                    node_type = "document",
                    content = "JWT token validation best practices"
                })

                create_committed_node({
                    parent_id = doc1_id,
                    node_type = "example",
                    content = "Secure OAuth implementation example"
                })

                create_committed_node({
                    node_type = "reference",
                    content = "OAuth security recommendations RFC"
                })
            end)

            it("should combine path and type filters", function()
                local category_nodes = reader.for_kb(test_ctx.kb_id)
                    :of_type("category")
                    :all()

                expect(#category_nodes).to_equal(1)
                local category = category_nodes[1]

                local results = reader.for_kb(test_ctx.kb_id)
                    :under(category.path)
                    :of_type("document")
                    :all()

                expect(#results).to_equal(2)
                for _, node in ipairs(results) do
                    expect(node.node_type).to_equal("document")
                end
            end)

            it("should combine parent and type filters", function()
                local category = reader.for_kb(test_ctx.kb_id)
                    :of_type("category")
                    :one()

                expect(category).not_to_be_nil()

                local children = reader.for_kb(test_ctx.kb_id)
                    :children_of(category.id)
                    :of_type("document")
                    :all()

                expect(#children).to_equal(2)
            end)

            it("should combine search with type filtering", function()
                local oauth_docs = reader.for_kb(test_ctx.kb_id)
                    :search("OAuth")
                    :of_type("document")
                    :all()

                expect(#oauth_docs).to_be_greater_than(0)
                for _, doc in ipairs(oauth_docs) do
                    expect(doc.node_type).to_equal("document")
                    local content_lower = string.lower(doc.content or "")
                    expect(content_lower:find("oauth")).not_to_be_nil()
                end
            end)

            it("should combine search with path filtering", function()
                local category = reader.for_kb(test_ctx.kb_id)
                    :of_type("category")
                    :one()

                expect(category).not_to_be_nil()

                local results = reader.for_kb(test_ctx.kb_id)
                    :under(category.path)
                    :search("OAuth")
                    :all()

                expect(#results).to_be_greater_than(0)
                for _, result in ipairs(results) do
                    expect(result.path:sub(1, #category.path)).to_equal(category.path)
                    local content_lower = string.lower(result.content or "")
                    expect(content_lower:find("oauth")).not_to_be_nil()
                end
            end)
        end)

        describe("Include/Exclude Options", function()
            before_each(function()
                create_committed_node({
                    content = "Test content with rich metadata",
                    metadata = {
                        important = true,
                        category = "test",
                        tags = {"demo", "example"},
                        author = "test_author"
                    }
                })
            end)

            it("should exclude content when requested", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :exclude_content()
                    :all()

                expect(#results).to_equal(1)
                expect(results[1].content).to_be_nil()
                expect(results[1].content_type).to_be_nil()
            end)

            it("should exclude metadata when requested", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :exclude_metadata()
                    :all()

                expect(#results).to_equal(1)
                expect(results[1].metadata).to_be_nil()
            end)

            it("should include content by default", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :all()

                expect(#results).to_equal(1)
                expect(results[1].content).not_to_be_nil()
                expect(results[1].content).to_contain("Test content")
            end)

            it("should parse metadata by default", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :all()

                expect(#results).to_equal(1)
                expect(type(results[1].metadata)).to_equal("table")
                expect(results[1].metadata.important).to_be_true()
                expect(results[1].metadata.category).to_equal("test")
                expect(results[1].metadata.tags).to_contain("demo")
            end)

            it("should support chaining include/exclude options", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :exclude_content()
                    :include_metadata()
                    :all()

                expect(#results).to_equal(1)
                expect(results[1].content).to_be_nil()
                expect(results[1].metadata).not_to_be_nil()
                expect(type(results[1].metadata)).to_equal("table")
            end)
        end)

        describe("Result Methods", function()
            before_each(function()
                for i = 1, 7 do
                    create_committed_node({
                        node_type = "test_item",
                        content = "Test item " .. i,
                        metadata = {sequence = i}
                    })
                end
            end)

            it("should return all results", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :of_type("test_item")
                    :all()

                expect(#results).to_equal(7)
            end)

            it("should return first N results", function()
                local results = reader.for_kb(test_ctx.kb_id)
                    :of_type("test_item")
                    :first(3)

                expect(#results).to_equal(3)
            end)

            it("should return single result or nil", function()
                local result = reader.for_kb(test_ctx.kb_id)
                    :of_type("test_item")
                    :one()

                expect(result).not_to_be_nil()
                expect(result.node_type).to_equal("test_item")

                local no_result = reader.for_kb(test_ctx.kb_id)
                    :of_type("nonexistent")
                    :one()

                expect(no_result).to_be_nil()
            end)

            it("should count results accurately", function()
                local count = reader.for_kb(test_ctx.kb_id)
                    :of_type("test_item")
                    :count()

                expect(count).to_equal(7)
            end)

            it("should check existence correctly", function()
                local exists = reader.for_kb(test_ctx.kb_id)
                    :of_type("test_item")
                    :exists()

                expect(exists).to_be_true()

                local not_exists = reader.for_kb(test_ctx.kb_id)
                    :of_type("nonexistent")
                    :exists()

                expect(not_exists).to_be_false()
            end)

            it("should support pagination with limit and offset", function()
                local first_page = reader.for_kb(test_ctx.kb_id)
                    :of_type("test_item")
                    :limit(3)
                    :all()

                expect(#first_page).to_equal(3)

                local second_page = reader.for_kb(test_ctx.kb_id)
                    :of_type("test_item")
                    :limit(3)
                    :offset(3)
                    :all()

                expect(#second_page).to_equal(3)

                -- Verify different results
                expect(first_page[1].id).not_to_equal(second_page[1].id)
            end)
        end)

        describe("Edge Cases and Error Handling", function()
            it("should handle empty knowledge base", function()
                local empty_kb_id = uuid.v7()
                execute_op_with_commit(ops.COMMAND_TYPES.CREATE_COMPONENT, {
                    id = empty_kb_id,
                    component_id = empty_kb_id,
                    config = {}
                })

                local results = reader.for_kb(empty_kb_id)
                    :all()

                expect(#results).to_equal(0)
                expect(reader.for_kb(empty_kb_id):count()).to_equal(0)
                expect(reader.for_kb(empty_kb_id):exists()).to_be_false()
                expect(reader.for_kb(empty_kb_id):one()).to_be_nil()
            end)

            it("should handle invalid search queries gracefully", function()
                create_committed_node({content = "Test content"})

                -- Empty search should not cause error - should be ignored and return all nodes
                local results = reader.for_kb(test_ctx.kb_id)
                    :search("")
                    :all()

                expect(#results).to_be_greater_than(0)

                -- Test with whitespace-only search
                local whitespace_results = reader.for_kb(test_ctx.kb_id)
                    :search("   ")
                    :all()

                expect(#whitespace_results).to_be_greater_than(0)
            end)

            it("should handle limit and offset errors", function()
                local success = pcall(function()
                    reader.for_kb(test_ctx.kb_id)
                        :limit(-1)
                end)
                expect(success).to_be_false()

                success = pcall(function()
                    reader.for_kb(test_ctx.kb_id)
                        :offset(-1)
                end)
                expect(success).to_be_false()
            end)
        end)

        describe("Immutability", function()
            it("should not modify original reader", function()
                local reader1 = reader.for_kb(test_ctx.kb_id)
                local reader2 = reader1:of_type("document")
                local reader3 = reader2:search("test")

                -- Original readers should not be modified
                expect(reader1._node_types).to_be_nil()
                expect(reader1._search_query).to_be_nil()

                expect(reader2._node_types).not_to_be_nil()
                expect(reader2._search_query).to_be_nil()

                expect(reader3._node_types).not_to_be_nil()
                expect(reader3._search_query).not_to_be_nil()
            end)

            it("should support complex chaining", function()
                create_committed_node({
                    node_type = "document",
                    content = "Test document for chaining"
                })

                -- Test chaining without terminal methods at the end
                local results = reader.for_kb(test_ctx.kb_id)
                    :of_type("document")
                    :search("test")
                    :include_content()
                    :exclude_metadata()
                    :all()

                expect(#results).to_be_greater_than(0)
                expect(results[1].content).not_to_be_nil()
                expect(results[1].metadata).to_be_nil()

                -- Test :first() separately (it returns results, not chainable reader)
                local first_results = reader.for_kb(test_ctx.kb_id)
                    :of_type("document")
                    :search("test")
                    :first(5)

                expect(type(first_results)).to_equal("table")
                expect(#first_results).to_be_greater_than(0)
            end)
        end)
    end)
end

return test.run_cases(run_tests)