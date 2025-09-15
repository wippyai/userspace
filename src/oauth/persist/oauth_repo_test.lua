local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local json = require("json")
local time = require("time")
local env = require("env")
local oauth_repo = require("oauth_repo")

local function define_tests()
    describe("OAuth Repository", function()
        -- Test data
        local test_data = {
            component_id = uuid.v7(),
            component_id2 = uuid.v7(),
            component_id3 = uuid.v7(),
            schedule_id = uuid.v7(),
            schedule_id2 = uuid.v7()
        }

        -- Function to create test connection data with current timestamp
        local function get_test_connection_data(schedule_id)
            return {
                provider = "google",
                connection_name = "Test Google Connection",
                connection_description = "Test connection for unit tests",
                schedule_id = schedule_id,
                scopes_granted = "email profile https://www.googleapis.com/auth/gmail.readonly",
                token_type = "Bearer",
                expires_at = time.now():unix() + 3600, -- 1 hour from now
                refresh_expires_at = time.now():unix() + (30 * 24 * 3600), -- 30 days from now
                tokens = {
                    access_token = "ya29.test_access_token_12345",
                    refresh_token = "1//04test_refresh_token_67890",
                    id_token = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test",
                    scope = "email profile https://www.googleapis.com/auth/gmail.readonly"
                },
                client_credentials = {
                    client_id = "123456789.apps.googleusercontent.com",
                    client_secret = "GOCSPX-test_client_secret"
                },
                user_profile = {
                    provider_user_id = "123456789",
                    email = "test@example.com",
                    display_name = "Test User",
                    username = "testuser",
                    avatar_url = "https://lh3.googleusercontent.com/test-avatar",
                    verified_email = true
                },
                provider_specific = {
                    locale = "en",
                    picture = "https://lh3.googleusercontent.com/test-picture",
                    given_name = "Test",
                    family_name = "User",
                    hd = "example.com"
                },
                oauth_flow = {
                    code_verifier = "dBjftJeZ4CVP-mB9v-daBfL-mm0X_lbVWdmvt4",
                    code_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                    state = "test_state_random_string",
                    nonce = "test_nonce_12345"
                }
            }
        end

        -- Clean up test data after all tests
        after_all(function()
            local db, err = sql.get("app:db")
            if err then
                error("Failed to connect to database: " .. err)
            end

            -- Delete test connections
            db:execute("DELETE FROM oauth_connections WHERE component_id IN (?, ?, ?)",
                { test_data.component_id, test_data.component_id2, test_data.component_id3 })

            db:release()
        end)

        -- Clean up before each test to ensure isolation
        before_each(function()
            local db, err = sql.get("app:db")
            if err then
                error("Failed to connect to database: " .. err)
            end

            -- Clean up our specific test data only (not all test data)
            db:execute("DELETE FROM oauth_connections WHERE component_id IN (?, ?, ?)",
                { test_data.component_id, test_data.component_id2, test_data.component_id3 })
            db:release()
        end)

        it("should require ENCRYPTION_KEY environment variable", function()
            local encryption_key, err = env.get("ENCRYPTION_KEY")

            -- Skip this test if ENCRYPTION_KEY is not available
            if not encryption_key or encryption_key == "" then
                pending("ENCRYPTION_KEY environment variable not set")
                return
            end

            expect(encryption_key).not_to_be_nil()
            expect(encryption_key).not_to_equal("")
        end)

        describe("create_connection", function()

            it("should create a new OAuth connection successfully", function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                local result, err = oauth_repo.create_connection(test_data.component_id, test_connection_data)

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.success).to_be_true()
                expect(result.component_id).to_equal(test_data.component_id)
                expect(result.created_at).not_to_be_nil()
            end)

            it("should create connection with schedule_id", function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                local unique_component_id = uuid.v7() -- Use unique ID for this test
                local result, err = oauth_repo.create_connection(unique_component_id, test_connection_data)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify schedule_id was stored
                local connection, err = oauth_repo.get_connection(unique_component_id)
                expect(err).to_be_nil()
                expect(connection.schedule_id).to_equal(test_data.schedule_id)

                -- Clean up
                oauth_repo.delete_connection(unique_component_id)
            end)

            it("should create connection without schedule_id", function()
                local test_connection_data = get_test_connection_data(nil)
                local result, err = oauth_repo.create_connection(test_data.component_id2, test_connection_data)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify schedule_id is nil
                local connection, err = oauth_repo.get_connection(test_data.component_id2)
                expect(err).to_be_nil()
                expect(connection.schedule_id).to_be_nil()
            end)

            it("should fail with missing component_id", function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                local result, err = oauth_repo.create_connection(nil, test_connection_data)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Component ID is required")
            end)

            it("should fail with missing connection_data", function()
                local unique_component_id = uuid.v7()
                local result, err = oauth_repo.create_connection(unique_component_id, nil)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Connection data is required")
            end)

            it("should fail with missing provider", function()
                local unique_component_id = uuid.v7()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                test_connection_data.provider = nil

                local result, err = oauth_repo.create_connection(unique_component_id, test_connection_data)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Provider is required")
            end)

            it("should fail with missing connection_name", function()
                local unique_component_id = uuid.v7()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                test_connection_data.connection_name = nil

                local result, err = oauth_repo.create_connection(unique_component_id, test_connection_data)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Connection name is required")
            end)

            it("should fail with missing tokens", function()
                local unique_component_id = uuid.v7()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                test_connection_data.tokens = nil

                local result, err = oauth_repo.create_connection(unique_component_id, test_connection_data)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Tokens are required")
            end)

        end)

        describe("get_connection", function()

            before_each(function()
                -- Create test connection
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)
            end)

            it("should retrieve complete OAuth connection", function()
                local connection, err = oauth_repo.get_connection(test_data.component_id)

                expect(err).to_be_nil()
                expect(connection).not_to_be_nil()

                -- Check public fields
                expect(connection.component_id).to_equal(test_data.component_id)
                expect(connection.provider).to_equal("google")
                expect(connection.connection_name).to_equal("Test Google Connection")
                expect(connection.schedule_id).to_equal(test_data.schedule_id)
                expect(connection.scopes_granted).to_equal("email profile https://www.googleapis.com/auth/gmail.readonly")
                expect(connection.connection_state).to_equal("active")
                expect(connection.expires_at).not_to_be_nil()

                -- Check decrypted data
                expect(connection.tokens).not_to_be_nil()
                expect(connection.tokens.access_token).to_equal("ya29.test_access_token_12345")
                expect(connection.tokens.refresh_token).to_equal("1//04test_refresh_token_67890")

                expect(connection.user_profile).not_to_be_nil()
                expect(connection.user_profile.email).to_equal("test@example.com")
                expect(connection.user_profile.display_name).to_equal("Test User")

                expect(connection.client_credentials).not_to_be_nil()
                expect(connection.client_credentials.client_id).to_equal("123456789.apps.googleusercontent.com")
            end)

            it("should fail with missing component_id", function()
                local connection, err = oauth_repo.get_connection(nil)

                expect(connection).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Component ID is required")
            end)

            it("should fail with non-existent component_id", function()
                local connection, err = oauth_repo.get_connection("non-existent-id")

                expect(connection).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("OAuth connection not found")
            end)

        end)

        describe("get_connection_metadata", function()

            before_each(function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)
            end)

            it("should retrieve connection metadata without decryption", function()
                local metadata, err = oauth_repo.get_connection_metadata(test_data.component_id)

                expect(err).to_be_nil()
                expect(metadata).not_to_be_nil()

                -- Check public fields are present
                expect(metadata.component_id).to_equal(test_data.component_id)
                expect(metadata.provider).to_equal("google")
                expect(metadata.connection_name).to_equal("Test Google Connection")
                expect(metadata.schedule_id).to_equal(test_data.schedule_id)
                expect(metadata.expires_at).not_to_be_nil()

                -- Check encrypted fields are NOT present
                expect(metadata.tokens).to_be_nil()
                expect(metadata.user_profile).to_be_nil()
                expect(metadata.client_credentials).to_be_nil()
                expect(metadata.oauth_data_encrypted).to_be_nil()
            end)

        end)

        describe("get_access_token", function()

            before_each(function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)
            end)

            it("should retrieve access token with expiration", function()
                local token_data, err = oauth_repo.get_access_token(test_data.component_id)

                expect(err).to_be_nil()
                expect(token_data).not_to_be_nil()
                expect(token_data.access_token).to_equal("ya29.test_access_token_12345")
                expect(token_data.expires_at).not_to_be_nil()
            end)

            it("should fail with missing component_id", function()
                local token_data, err = oauth_repo.get_access_token(nil)

                expect(token_data).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Component ID is required")
            end)

        end)

        describe("update_tokens", function()

            before_each(function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)
            end)

            it("should update tokens successfully", function()
                local new_tokens = {
                    access_token = "ya29.new_access_token_updated",
                    refresh_token = "1//04new_refresh_token_updated",
                    id_token = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.new"
                }
                local new_expires_at = time.now():unix() + 7200 -- 2 hours from now

                local result, err = oauth_repo.update_tokens(test_data.component_id, new_tokens, new_expires_at)

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.success).to_be_true()
                expect(result.updated_at).not_to_be_nil()

                -- Verify tokens were updated
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                expect(connection.tokens.access_token).to_equal("ya29.new_access_token_updated")
                expect(connection.tokens.refresh_token).to_equal("1//04new_refresh_token_updated")
                expect(connection.expires_at).to_equal(new_expires_at)
                expect(connection.last_token_refresh).not_to_be_nil()
            end)

            it("should update tokens without changing expiration", function()
                -- Get the current expires_at value from the created connection
                local original_connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                local original_expires_at = original_connection.expires_at

                local new_tokens = {
                    access_token = "ya29.new_access_token_no_expiration"
                }

                local result, err = oauth_repo.update_tokens(test_data.component_id, new_tokens)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify only token was updated, expiration unchanged
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(connection.tokens.access_token).to_equal("ya29.new_access_token_no_expiration")
                expect(connection.expires_at).to_equal(original_expires_at)
            end)

            it("should fail with missing tokens", function()
                local result, err = oauth_repo.update_tokens(test_data.component_id, nil)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Tokens are required")
            end)

            it("should fail with invalid expires_at", function()
                local new_tokens = { access_token = "test" }

                local result, err = oauth_repo.update_tokens(test_data.component_id, new_tokens, "invalid")

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("expires_at must be a number")
            end)

        end)

        describe("update_connection", function()

            before_each(function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)
            end)

            it("should update all connection fields successfully", function()
                local update_data = {
                    provider = "github",
                    connection_name = "Updated GitHub Connection",
                    connection_description = "Updated description for testing",
                    scopes_granted = "user read:org public_repo",
                    connection_state = "authenticated",
                    token_type = "bearer",
                    expires_at = time.now():unix() + 7200, -- 2 hours from now
                    refresh_expires_at = time.now():unix() + (60 * 24 * 3600), -- 60 days from now
                    schedule_id = test_data.schedule_id2,
                    tokens = {
                        access_token = "gho_new_github_token_12345",
                        refresh_token = "ghr_new_refresh_token_67890",
                        scope = "user read:org public_repo"
                    },
                    user_profile = {
                        provider_user_id = "987654321",
                        email = "updated@example.com",
                        display_name = "Updated User",
                        username = "updateduser",
                        avatar_url = "https://avatars.githubusercontent.com/updated-avatar"
                    },
                    provider_specific = {
                        login = "updateduser",
                        bio = "Updated bio",
                        location = "Updated Location"
                    },
                    oauth_flow = {
                        state = "updated_state_token"
                    }
                }

                local result, err = oauth_repo.update_connection(test_data.component_id, update_data)

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.success).to_be_true()
                expect(result.updated_at).not_to_be_nil()

                -- Verify all fields were updated
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()

                -- Check metadata fields
                expect(connection.provider).to_equal("github")
                expect(connection.connection_name).to_equal("Updated GitHub Connection")
                expect(connection.connection_description).to_equal("Updated description for testing")
                expect(connection.scopes_granted).to_equal("user read:org public_repo")
                expect(connection.connection_state).to_equal("authenticated")
                expect(connection.token_type).to_equal("bearer")
                expect(connection.expires_at).to_equal(update_data.expires_at)
                expect(connection.refresh_expires_at).to_equal(update_data.refresh_expires_at)
                expect(connection.schedule_id).to_equal(test_data.schedule_id2)

                -- Check encrypted data
                expect(connection.tokens.access_token).to_equal("gho_new_github_token_12345")
                expect(connection.tokens.refresh_token).to_equal("ghr_new_refresh_token_67890")
                expect(connection.user_profile.email).to_equal("updated@example.com")
                expect(connection.user_profile.display_name).to_equal("Updated User")
                expect(connection.provider_specific.bio).to_equal("Updated bio")
                expect(connection.oauth_flow.state).to_equal("updated_state_token")
            end)

            it("should update only scopes_granted (re-authorization scenario)", function()
                local original_connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()

                local update_data = {
                    scopes_granted = "email profile https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/drive",
                    tokens = {
                        access_token = "ya29.reauth_access_token_67890",
                        refresh_token = original_connection.tokens.refresh_token, -- Keep same refresh token
                        scope = "email profile https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/drive"
                    }
                }

                local result, err = oauth_repo.update_connection(test_data.component_id, update_data)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify scopes were updated but other fields preserved
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                expect(connection.scopes_granted).to_equal("email profile https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/drive")
                expect(connection.tokens.access_token).to_equal("ya29.reauth_access_token_67890")
                expect(connection.connection_name).to_equal(original_connection.connection_name) -- Unchanged
                expect(connection.provider).to_equal(original_connection.provider) -- Unchanged
                expect(connection.user_profile.email).to_equal(original_connection.user_profile.email) -- Unchanged
            end)

            it("should update partial fields without affecting others", function()
                local original_connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()

                local update_data = {
                    connection_name = "Partially Updated Connection",
                    expires_at = time.now():unix() + 5400, -- 1.5 hours from now
                    user_profile = {
                        provider_user_id = original_connection.user_profile.provider_user_id, -- Keep same
                        email = "partially_updated@example.com",
                        display_name = "Partially Updated User",
                        username = original_connection.user_profile.username, -- Keep same
                        avatar_url = original_connection.user_profile.avatar_url -- Keep same
                    }
                }

                local result, err = oauth_repo.update_connection(test_data.component_id, update_data)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify partial updates
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()

                -- Updated fields
                expect(connection.connection_name).to_equal("Partially Updated Connection")
                expect(connection.expires_at).to_equal(update_data.expires_at)
                expect(connection.user_profile.email).to_equal("partially_updated@example.com")
                expect(connection.user_profile.display_name).to_equal("Partially Updated User")

                -- Unchanged fields
                expect(connection.provider).to_equal(original_connection.provider)
                expect(connection.scopes_granted).to_equal(original_connection.scopes_granted)
                expect(connection.tokens.access_token).to_equal(original_connection.tokens.access_token)
                expect(connection.user_profile.username).to_equal(original_connection.user_profile.username)
                expect(connection.provider_specific.locale).to_equal(original_connection.provider_specific.locale)
            end)

            it("should handle empty description update", function()
                local update_data = {
                    connection_description = ""
                }

                local result, err = oauth_repo.update_connection(test_data.component_id, update_data)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify description was cleared (set to NULL)
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                expect(connection.connection_description).to_be_nil()
            end)

            it("should handle schedule_id clearing", function()
                local update_data = {
                    schedule_id = ""
                }

                local result, err = oauth_repo.update_connection(test_data.component_id, update_data)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify schedule_id was cleared
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                expect(connection.schedule_id).to_be_nil()
            end)

            it("should update client_credentials", function()
                local update_data = {
                    client_credentials = {
                        client_id = "new_client_id_12345",
                        client_secret = "GOCSPX-new_client_secret_67890"
                    }
                }

                local result, err = oauth_repo.update_connection(test_data.component_id, update_data)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify client credentials were updated
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                expect(connection.client_credentials.client_id).to_equal("new_client_id_12345")
                expect(connection.client_credentials.client_secret).to_equal("GOCSPX-new_client_secret_67890")
            end)

            it("should fail with missing component_id", function()
                local update_data = { connection_name = "Test" }
                local result, err = oauth_repo.update_connection(nil, update_data)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Component ID is required")
            end)

            it("should fail with missing connection_data", function()
                local result, err = oauth_repo.update_connection(test_data.component_id, nil)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Connection data is required")
            end)

            it("should fail with non-existent component_id", function()
                local update_data = { connection_name = "Test" }
                local result, err = oauth_repo.update_connection("non-existent-id", update_data)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("OAuth connection not found")
            end)

            it("should verify data is properly encrypted after update", function()
                local update_data = {
                    tokens = {
                        access_token = "ya29.super_secret_new_token_99999",
                        refresh_token = "1//04super_secret_refresh_99999"
                    },
                    user_profile = {
                        provider_user_id = "999999999",
                        email = "super_secret@example.com"
                    },
                    client_credentials = {
                        client_secret = "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9999"
                    }
                }

                local result, err = oauth_repo.update_connection(test_data.component_id, update_data)
                expect(err).to_be_nil()

                -- Query database directly to verify encryption
                local db, err = sql.get("app:db")
                expect(err).to_be_nil()

                local query = sql.builder.select("oauth_data_encrypted", "access_token_encrypted")
                    :from("oauth_connections")
                    :where("component_id = ?", test_data.component_id)

                local executor = query:run_with(db)
                local results, err = executor:query()
                db:release()

                expect(err).to_be_nil()
                expect(#results).to_equal(1)

                local raw_record = results[1]

                -- Verify the sensitive data is not in plain text
                expect(raw_record.oauth_data_encrypted:find("ya29.super_secret_new_token_99999", 1, true)).to_be_nil()
                expect(raw_record.oauth_data_encrypted:find("super_secret@example.com", 1, true)).to_be_nil()
                expect(raw_record.oauth_data_encrypted:find("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9999", 1, true)).to_be_nil()
                expect(raw_record.access_token_encrypted:find("ya29.super_secret_new_token_99999", 1, true)).to_be_nil()

                -- Verify data can be decrypted correctly
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                expect(connection.tokens.access_token).to_equal("ya29.super_secret_new_token_99999")
                expect(connection.user_profile.email).to_equal("super_secret@example.com")
                expect(connection.client_credentials.client_secret).to_equal("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9999")
            end)

        end)

        describe("update_schedule_id", function()

            before_each(function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)
            end)

            it("should update schedule_id successfully", function()
                local result, err = oauth_repo.update_schedule_id(test_data.component_id, test_data.schedule_id2)

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.success).to_be_true()
                expect(result.updated_at).not_to_be_nil()

                -- Verify schedule_id was updated
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                expect(connection.schedule_id).to_equal(test_data.schedule_id2)
            end)

            it("should clear schedule_id when set to nil", function()
                local result, err = oauth_repo.update_schedule_id(test_data.component_id, nil)

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify schedule_id was cleared
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(err).to_be_nil()
                expect(connection.schedule_id).to_be_nil()
            end)

            it("should fail with missing component_id", function()
                local result, err = oauth_repo.update_schedule_id(nil, test_data.schedule_id2)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Component ID is required")
            end)

            it("should fail with non-existent component_id", function()
                local result, err = oauth_repo.update_schedule_id("non-existent-id", test_data.schedule_id2)

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("OAuth connection not found")
            end)

        end)

        describe("list_by_provider", function()

            before_each(function()
                -- Create multiple connections
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)

                local github_data = get_test_connection_data(test_data.schedule_id2)
                github_data.provider = "github"
                github_data.connection_name = "Test GitHub Connection"
                oauth_repo.create_connection(test_data.component_id2, github_data)
            end)

            it("should list connections by provider", function()
                local connections, err = oauth_repo.list_by_provider("google")

                expect(err).to_be_nil()
                expect(connections).not_to_be_nil()
                expect(#connections >= 1).to_be_true() -- At least our test connection should exist

                -- Find our test connection in the results
                local test_connection = nil
                for _, conn in ipairs(connections) do
                    if conn.component_id == test_data.component_id then
                        test_connection = conn
                        break
                    end
                end

                expect(test_connection).not_to_be_nil()
                expect(test_connection.provider).to_equal("google")
                expect(test_connection.connection_name).to_equal("Test Google Connection")
                expect(test_connection.schedule_id).to_equal(test_data.schedule_id)

                -- Check that encrypted data is not included in any result
                for _, conn in ipairs(connections) do
                    expect(conn.oauth_data_encrypted).to_be_nil()
                end
            end)

            it("should return empty list for non-existent provider", function()
                local connections, err = oauth_repo.list_by_provider("non-existent")

                expect(err).to_be_nil()
                expect(connections).not_to_be_nil()
                expect(#connections).to_equal(0)
            end)

            it("should fail with missing provider name", function()
                local connections, err = oauth_repo.list_by_provider(nil)

                expect(connections).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Provider name is required")
            end)

        end)

        describe("list_by_schedule_id", function()

            before_each(function()
                -- Create connections with different schedule_ids
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)

                local github_data = get_test_connection_data(test_data.schedule_id2)
                github_data.provider = "github"
                github_data.connection_name = "Test GitHub Connection"
                oauth_repo.create_connection(test_data.component_id2, github_data)
            end)

            it("should list connections by schedule_id", function()
                local connections, err = oauth_repo.list_by_schedule_id(test_data.schedule_id)

                expect(err).to_be_nil()
                expect(connections).not_to_be_nil()
                expect(#connections >= 1).to_be_true() -- At least our test connection should exist

                -- Find our test connection in the results
                local test_connection = nil
                for _, conn in ipairs(connections) do
                    if conn.component_id == test_data.component_id then
                        test_connection = conn
                        break
                    end
                end

                expect(test_connection).not_to_be_nil()
                expect(test_connection.schedule_id).to_equal(test_data.schedule_id)
                expect(test_connection.provider).to_equal("google")

                -- Check that encrypted data is not included in any result
                for _, conn in ipairs(connections) do
                    expect(conn.oauth_data_encrypted).to_be_nil()
                end
            end)

            it("should return empty list for non-existent schedule_id", function()
                local connections, err = oauth_repo.list_by_schedule_id("non-existent-schedule-id")

                expect(err).to_be_nil()
                expect(connections).not_to_be_nil()
                expect(#connections).to_equal(0)
            end)

            it("should fail with missing schedule_id", function()
                local connections, err = oauth_repo.list_by_schedule_id(nil)

                expect(connections).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("Schedule ID is required")
            end)

        end)

        describe("disable_connection", function()

            before_each(function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)
            end)

            it("should disable connection successfully", function()
                local result, err = oauth_repo.disable_connection(test_data.component_id)

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.success).to_be_true()
                expect(result.updated_at).not_to_be_nil()

                -- Verify connection was disabled
                local metadata, err = oauth_repo.get_connection_metadata(test_data.component_id)
                expect(err).to_be_nil()
                expect(metadata.connection_state).to_equal("disabled")
            end)

            it("should fail with non-existent component_id", function()
                local result, err = oauth_repo.disable_connection("non-existent-id")

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("OAuth connection not found")
            end)

        end)

        describe("delete_connection", function()

            before_each(function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)
            end)

            it("should delete connection successfully", function()
                local result, err = oauth_repo.delete_connection(test_data.component_id)

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.success).to_be_true()
                expect(result.deleted).to_be_true()

                -- Verify connection was deleted
                local connection, err = oauth_repo.get_connection(test_data.component_id)
                expect(connection).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("OAuth connection not found")
            end)

            it("should fail with non-existent component_id", function()
                local result, err = oauth_repo.delete_connection("non-existent-id")

                expect(result).to_be_nil()
                expect(err).not_to_be_nil()
                expect(err).to_match("OAuth connection not found")
            end)

        end)

        describe("encryption/decryption", function()

            it("should verify that data is actually encrypted in database", function()
                local test_connection_data = get_test_connection_data(test_data.schedule_id)
                oauth_repo.create_connection(test_data.component_id, test_connection_data)

                -- Query the database directly to verify data is encrypted
                local db, err = sql.get("app:db")
                expect(err).to_be_nil()

                local query = sql.builder.select("oauth_data_encrypted")
                    :from("oauth_connections")
                    :where("component_id = ?", test_data.component_id)

                local executor = query:run_with(db)
                local results, err = executor:query()

                db:release()

                expect(err).to_be_nil()
                expect(#results).to_equal(1)

                local raw_record = results[1]

                -- Verify the stored data is not in plain text
                expect(raw_record.oauth_data_encrypted:find("ya29.test_access_token_12345", 1, true)).to_be_nil()
                expect(raw_record.oauth_data_encrypted:find("test@example.com", 1, true)).to_be_nil()
                expect(raw_record.oauth_data_encrypted:find("GOCSPX-test_client_secret", 1, true)).to_be_nil()
            end)

            it("should properly encrypt and decrypt complex nested data", function()
                -- Create connection with complex data using a unique component_id
                local unique_component_id = uuid.v7()
                local complex_data = get_test_connection_data(test_data.schedule_id)
                complex_data.provider_specific.complex_nested = {
                    array = {1, 2, 3, "test"},
                    boolean = true,
                    nested_object = {
                        deep_value = "deep_test"
                    }
                }

                local result, err = oauth_repo.create_connection(unique_component_id, complex_data)
                expect(err).to_be_nil()

                -- Retrieve and verify all data is intact
                local connection, err = oauth_repo.get_connection(unique_component_id)
                expect(err).to_be_nil()

                -- Check that complex nested data survived encryption/decryption
                expect(connection.provider_specific.complex_nested).not_to_be_nil()
                expect(connection.provider_specific.complex_nested.array[4]).to_equal("test")
                expect(connection.provider_specific.complex_nested.boolean).to_be_true()
                expect(connection.provider_specific.complex_nested.nested_object.deep_value).to_equal("deep_test")

                -- Clean up
                oauth_repo.delete_connection(unique_component_id)
            end)

        end)

    end)
end

return test.run_cases(define_tests)