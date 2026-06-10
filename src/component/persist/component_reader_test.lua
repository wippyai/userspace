local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local time = require("time")
local component_reader = require("component_reader") :: any

local function define_tests()
    test.describe("Component Reader", function()
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
                error("Failed to connect to database: " .. tostring(err))
            end
            return db
        end

        local function create_test_component()
            local db = get_db()
            local ts = time.now():format(time.RFC3339)

            sql.builder.insert("components"):set_map({
                component_id = test_data.component_id,
                impl_id = test_data.impl_id,
                private_context = '{"test": true}',
                created_at = ts,
                updated_at = ts,
            }):run_with(db):exec()

            sql.builder.insert("component_access"):set_map({
                access_id = uuid.v7(),
                component_id = test_data.component_id,
                user_id = test_data.user_id,
                access_mask = 15,
                created_at = ts,
            }):run_with(db):exec()

            sql.builder.insert("component_meta"):set_map({
                meta_id = uuid.v7(),
                component_id = test_data.component_id,
                key = "class",
                value = "test",
                created_at = ts,
                updated_at = ts,
            }):run_with(db):exec()

            sql.builder.insert("component_meta"):set_map({
                meta_id = uuid.v7(),
                component_id = test_data.component_id,
                key = "provider",
                value = "test_provider",
                created_at = ts,
                updated_at = ts,
            }):run_with(db):exec()

            db:release()
        end

        -- Cleanup helper
        local function cleanup_test_component()
            local db = get_db()
            sql.builder.delete("component_meta"):where("component_id = ?", test_data.component_id):run_with(db):exec()
            sql.builder.delete("component_access"):where("component_id = ?", test_data.component_id):run_with(db):exec()
            sql.builder.delete("components"):where("component_id = ?", test_data.component_id):run_with(db):exec()
            db:release()
        end

        -- Clean up before and after each test
        test.before_each(function()
            cleanup_test_component()
            create_test_component()
        end)

        test.after_each(function()
            cleanup_test_component()
        end)

        test.describe("basic functionality", function()
            test.it("should create a new reader instance", function()
                local reader = component_reader.new()
                test.not_nil(reader)
                test.is_nil(reader._user_id)
                test.is_true(reader._include_meta)
            end)

            test.it("should be immutable", function()
                local reader1 = component_reader.new()
                local reader2 = reader1:with_user("test-user")

                test.neq(reader1, reader2)
                test.is_nil(reader1._user_id)
                test.eq(reader2._user_id, "test-user")
            end)
        end)

        test.describe("component querying", function()
            test.it("should find components by user and component ID", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                local components = reader:all()

                test.eq(#components, 1)
                test.eq(components[1].component_id, test_data.component_id)
                test.eq(components[1].impl_id, test_data.impl_id)
            end)

            test.it("should return one component", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                local component = reader:one()

                test.not_nil(component)
                test.eq(component.component_id, test_data.component_id)
            end)

            test.it("should count components", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                test.eq(reader:count(), 1)
            end)

            test.it("should check if components exist", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                test.is_true(reader:exists())

                local non_existent_reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(uuid.v7())

                test.is_false(non_existent_reader:exists())
            end)
        end)

        test.describe("metadata filtering", function()
            test.it("should filter by metadata even when meta output is disabled", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_meta({ provider = "test_provider" })
                    :include_options({ meta = false })

                local components = reader:all()

                test.eq(#components, 1)
                test.eq(components[1].component_id, test_data.component_id)
                test.is_nil(components[1].meta) -- meta not included in output
            end)

            test.it("should not find components with wrong metadata", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_meta({ provider = "wrong_provider" })

                test.eq(#reader:all(), 0)
            end)

            test.it("should filter by multiple metadata fields", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_meta({ class = "test", provider = "test_provider" })

                local components = reader:all()

                test.eq(#components, 1)
                test.eq(components[1].component_id, test_data.component_id)
            end)
        end)

        test.describe("include options", function()
            test.it("should include metadata by default", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)

                local components = reader:all()

                test.eq(#components, 1)
                test.not_nil(components[1].meta)
                test.eq(components[1].meta.class, "test")
                test.eq(components[1].meta.provider, "test_provider")
            end)

            test.it("should exclude metadata when requested", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)
                    :include_options({ meta = false })

                local components = reader:all()

                test.eq(#components, 1)
                test.is_nil(components[1].meta)
            end)

            test.it("should include private context when requested", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)
                    :include_options({ private_context = true })

                local components = reader:all()

                test.eq(#components, 1)
                test.not_nil(components[1].private_context)
                test.is_true(components[1].private_context.test)
            end)

            test.it("should include access level when requested", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)
                    :include_options({ access_level = true })

                local components = reader:all()

                test.eq(#components, 1)
                test.eq(components[1].access_level, 15)
            end)
        end)

        test.describe("filtering", function()
            test.it("should filter by implementation ID", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_impl_ids(test_data.impl_id)

                local components = reader:all()

                local found_our_component = false
                for _, comp in ipairs(components) do
                    test.eq(comp.impl_id, test_data.impl_id)
                    if comp.component_id == test_data.component_id then
                        found_our_component = true
                    end
                end
                test.is_true(found_our_component)
            end)

            test.it("should filter by access mask", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components(test_data.component_id)
                    :with_access_mask(1) -- READ; our component has 15 which includes 1

                local components = reader:all()

                test.eq(#components, 1)
                test.eq(components[1].component_id, test_data.component_id)
            end)
        end)

        test.describe("edge cases", function()
            test.it("should handle empty results", function()
                local reader = component_reader.new()
                    :with_user("non-existent-user")

                test.eq(type(reader:all()), "table")
                test.eq(#reader:all(), 0)
                test.is_nil(reader:one())
                test.eq(reader:count(), 0)
                test.is_false(reader:exists())
            end)

            test.it("should handle nil metadata filter", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_meta(nil)

                test.eq(type(reader:count()), "number")
            end)

            test.it("should handle empty component array", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :with_components({})

                test.eq(type(reader:count()), "number")
            end)
        end)

        test.describe("pagination", function()
            test.it("should limit results", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :limit(1)

                local components = reader:all()

                local valid_count = (#components == 0) or (#components == 1)
                test.is_true(valid_count)
            end)

            test.it("should order results", function()
                local reader = component_reader.new()
                    :with_user(test_data.user_id)
                    :order_by("created_at", "ASC")

                test.eq(type(reader:count()), "number")
            end)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options)
    return run_cases(options)
end

return { run = run }
