local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local component_reader = require("component_reader")

local function define_tests()
    describe("Component Reader", function()
        -- Test data with unique identifiers to avoid conflicts
        local test_data = {
            user_id = "test-reader-" .. uuid.v4():sub(1, 8),
            component_id = uuid.v7(),
            impl_id = "userspace.test:reader_test"
        }

        -- Helper to get database
        local function get_db()
            local db, err = sql.get("app:db")
            if err then
                error("Failed to connect to database: " .. err)
            end
            return db
        end

        -- Helper to create a test component
        local function create_test_component()
            local db = get_db()
            local timestamp = time.now():format(time.RFC3339)

            -- Insert component
            db:execute(
                "INSERT INTO components (component_id, impl_id, private_context, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                {test_data.component_id, test_data.impl_id, '{"test": true}', timestamp, timestamp}
            )

            -- Insert access
            db:execute(
                "INSERT INTO component_access (component_id, user_id, access_mask) VALUES (?, ?, ?)",
                {test_data.component_id, test_data.user_id, 15}
            )

            -- Insert metadata
            db:execute(
                "INSERT INTO component_meta (meta_id, component_id, key, value, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                {uuid.v7(), test_data.component_id, "class", "test", timestamp, timestamp}
            )

            db:execute(
                "INSERT INTO component_meta (meta_id, component_id, key, value, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                {uuid.v7(), test_data.component_id, "provider", "test_provider", timestamp, timestamp}
            )

            db:release()
        end

        -- Cleanup helper
        local function cleanup_test_component()
            local db = get_db()
            db:execute("DELETE FROM component_meta WHERE component_id = ?", {test_data.component_id})
            db:execute("DELETE FROM component_access WHERE component_id = ?", {test_data.component_id})
            db:execute("DELETE FROM components WHERE component_id = ?", {test_data.component_id})
            db:release()
        end

        -- Clean up before and after each test
        before_each(function()
            cleanup_test_component()
            create_test_component()
        end)

        after_each(function()
            cleanup_test_component()
        end)

        describe("basic functionality", function()
            it("should create a new reader instance", function()
                local reader = component_reader.new()
                expect(reader).not_to_be_nil()
                expect(reader._user_id).to_be_nil()
                expect(reader._include_meta).to_be_true()
            end)

            it("should be immutable", function()
                local reader1 = component_reader.new() :: any
                local reader2 = reader1:with_user("test-user")

                expect(reader1).not_to_equal(reader2)
                expect(reader1._user_id).to_be_nil()
                expect(reader2._user_id).to_equal("test-user")
            end)
        end)

        describe("component querying", function()
            it("should find components by user and component ID", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                local components = reader:all()

                expect(#components).to_equal(1)
                expect(components[1].component_id).to_equal(test_data.component_id)
                expect(components[1].impl_id).to_equal(test_data.impl_id)
            end)

            it("should return one component", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                local component = reader:one()

                expect(component).not_to_be_nil()
                expect(component.component_id).to_equal(test_data.component_id)
            end)

            it("should count components", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                local count = reader:count()

                expect(count).to_equal(1)
            end)

            it("should check if components exist", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                expect(reader:exists()).to_be_true()

                local non_existent_reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(uuid.v7())

                expect(non_existent_reader:exists()).to_be_false()
            end)
        end)

        describe("metadata filtering - THE BUG FIX", function()
            it("should filter by metadata even when meta output is disabled", function()
                -- This is the key bug that was fixed
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_meta({provider = "test_provider"})
                    :include_options({meta = false})

                local components = reader:all()

                expect(#components).to_equal(1)
                expect(components[1].component_id).to_equal(test_data.component_id)
                expect(components[1].meta).to_be_nil() -- meta should not be included in output
            end)

            it("should not find components with wrong metadata", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_meta({provider = "wrong_provider"})

                local components = reader:all()

                expect(#components).to_equal(0)
            end)

            it("should filter by multiple metadata fields", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_meta({
                        class = "test",
                        provider = "test_provider"
                    })

                local components = reader:all()

                expect(#components).to_equal(1)
                expect(components[1].component_id).to_equal(test_data.component_id)
            end)
        end)

        describe("include options", function()
            it("should include metadata by default", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                local components = reader:all()

                expect(#components).to_equal(1)
                expect(components[1].meta).not_to_be_nil()
                expect(components[1].meta.class).to_equal("test")
                expect(components[1].meta.provider).to_equal("test_provider")
            end)

            it("should exclude metadata when requested", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)
                    :include_options({meta = false})

                local components = reader:all()

                expect(#components).to_equal(1)
                expect(components[1].meta).to_be_nil()
            end)

            it("should include private context when requested", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)
                    :include_options({private_context = true})

                local components = reader:all()

                expect(#components).to_equal(1)
                expect(components[1].private_context).not_to_be_nil()
                expect(components[1].private_context.test).to_be_true()
            end)

            it("should include access level when requested", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)
                    :include_options({access_level = true})

                local components = reader:all()

                expect(#components).to_equal(1)
                expect(components[1].access_level).to_equal(15)
            end)
        end)

        describe("filtering", function()
            it("should filter by implementation ID", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_impl_ids(test_data.impl_id)

                local components = reader:all()

                local found_our_component = false
                for _, comp in ipairs(components) do
                    expect(comp.impl_id).to_equal(test_data.impl_id)
                    if comp.component_id == test_data.component_id then
                        found_our_component = true
                    end
                end
                expect(found_our_component).to_be_true()
            end)

            it("should filter by access mask", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)
                    :with_access_mask(1) -- READ access - our component has 15 which includes 1

                local components = reader:all()

                expect(#components).to_equal(1)
                expect(components[1].component_id).to_equal(test_data.component_id)
            end)
        end)

        describe("edge cases", function()
            it("should handle empty results", function()
                local reader = (component_reader.new() :: any)
                    :with_user("non-existent-user")

                expect(reader:all()).to_be_type("table")
                expect(#reader:all()).to_equal(0)
                expect(reader:one()).to_be_nil()
                expect(reader:count()).to_equal(0)
                expect(reader:exists()).to_be_false()
            end)

            it("should handle nil metadata filter", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_meta(nil)

                -- Should not error
                local count = reader:count()
                expect(type(count)).to_equal("number")
            end)

            it("should handle empty component array", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components({})

                -- Should not error
                local count = reader:count()
                expect(type(count)).to_equal("number")
            end)
        end)

        describe("pagination", function()
            it("should limit results", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :limit(1)

                local components = reader:all()

                local valid_count = (#components == 0) or (#components == 1)
                expect(valid_count).to_be_true()
            end)

            it("should order results", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :order_by("created_at", "ASC")

                -- Should not error
                local count = reader:count()
                expect(type(count)).to_equal("number")
            end)
        end)
    end)
end

return test.run_cases(define_tests)
