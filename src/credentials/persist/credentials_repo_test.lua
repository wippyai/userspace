local sql = require("sql")
local test = require("test")
local uuid = require("uuid")
local json = require("json")
local credentials_repo = require("credentials_repo")
local time = require("time")
local env = require("env")

local function define_tests()
    describe("Credentials Repository", function()
        -- Test data
        local test_data = {
            component_id = uuid.v7(),
            component_id2 = uuid.v7(),
            component_id3 = uuid.v7()
        }

        -- Test connection data
        local test_connection_data = {
            connection_name = "My GitHub Connection",
            connection_description = "GitHub integration for development",
            credentials = {
                api_key = "ghp_1234567890abcdef",
                access_token = "gho_16C7e42F292c6912E7710c838347Ae178B4a",
                refresh_token = "ghr_1B4a6RbGiQ8aEr8E1GxQUEjnE4gN2k",
                client_id = "github_client_123",
                client_secret = "super_secret_client_secret_456",
                username = "testuser",
                endpoint = "https://api.github.com"
            },
            metadata = {
                provider = "github",
                environment = "production",
                created_by = "test_user",
                last_sync = time.now():format(time.RFC3339)
            }
        }

        -- Clean up test data after all tests
        after_all(function()
            local db, err = sql.get("app:db")
            if err then
                error("Failed to connect to database: " .. err)
            end

            -- Delete test credentials
            db:execute("DELETE FROM credentials_store WHERE component_id IN (?, ?, ?)",
                { test_data.component_id, test_data.component_id2, test_data.component_id3 })

            db:release()
        end)

        -- Clean up before each test to ensure isolation
        before_each(function()
            local db, err = sql.get("app:db")
            if err then
                error("Failed to connect to database: " .. err)
            end

            -- Clean up our specific test data only
            db:execute("DELETE FROM credentials_store WHERE component_id IN (?, ?, ?)",
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

        describe("store_credentials", function()
            it("should store credentials with connection data", function()
                local result, err = credentials_repo.store_credentials(
                    test_data.component_id,
                    test_connection_data
                )

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.component_id).to_equal(test_data.component_id)
                expect(result.success).to_be_true()
                expect(result.created_at).not_to_be_nil()
                expect(result.updated_at).not_to_be_nil()
            end)

            it("should store credentials without description", function()
                local connection_data = {
                    connection_name = "Slack Notifications",
                    credentials = {
                        bot_token = "xoxb-12345-67890-abcdef",
                        webhook_url = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"
                    }
                }

                local result, err = credentials_repo.store_credentials(
                    test_data.component_id2,
                    connection_data
                )

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.success).to_be_true()
            end)

            it("should store credentials without metadata", function()
                local connection_data = {
                    connection_name = "AWS S3 Access",
                    connection_description = "S3 bucket access",
                    credentials = {
                        access_key_id = "AKIAIOSFODNN7EXAMPLE",
                        secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                        region = "us-west-2"
                    }
                }

                local result, err = credentials_repo.store_credentials(
                    test_data.component_id3,
                    connection_data
                )

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.success).to_be_true()
            end)

            it("should update existing credentials (upsert behavior)", function()
                -- First create credentials
                local result, err = credentials_repo.store_credentials(
                    test_data.component_id,
                    test_connection_data
                )
                expect(err).to_be_nil()

                -- Update with new data
                local updated_data = {
                    connection_name = "Updated GitHub Connection",
                    connection_description = "Updated description",
                    credentials = {
                        api_key = "ghp_updated_token_123",
                        access_token = "gho_updated_access_token",
                        username = "updated_user"
                    },
                    metadata = {
                        provider = "github",
                        environment = "staging",
                        updated = true
                    }
                }

                result, err = credentials_repo.store_credentials(
                    test_data.component_id,
                    updated_data
                )

                expect(err).to_be_nil()
                expect(result.success).to_be_true()

                -- Verify the update
                local creds, err = credentials_repo.get_credentials(test_data.component_id)
                expect(err).to_be_nil()
                expect(creds.connection_name).to_equal("Updated GitHub Connection")
                expect(creds.credentials.api_key).to_equal("ghp_updated_token_123")
                expect(creds.credentials.username).to_equal("updated_user")
                expect(creds.metadata.environment).to_equal("staging")
                expect(creds.metadata.updated).to_be_true()
            end)

            it("should fail with missing component_id", function()
                local result, err = credentials_repo.store_credentials(
                    nil,
                    test_connection_data
                )
                expect(result).to_be_nil()
                expect(err:match("Component ID is required")).not_to_be_nil()
            end)

            it("should fail with missing connection_name", function()
                local invalid_data = {
                    credentials = { key = "value" }
                }

                local result, err = credentials_repo.store_credentials(
                    test_data.component_id,
                    invalid_data
                )
                expect(result).to_be_nil()
                expect(err:match("Connection name is required")).not_to_be_nil()
            end)

            it("should fail with missing credentials", function()
                local invalid_data = {
                    connection_name = "Test Connection"
                }

                local result, err = credentials_repo.store_credentials(
                    test_data.component_id,
                    invalid_data
                )
                expect(result).to_be_nil()
                expect(err:match("Credentials data is required")).not_to_be_nil()
            end)

            it("should fail with invalid credentials type", function()
                local invalid_data = {
                    connection_name = "Test Connection",
                    credentials = "not a table"
                }

                local result, err = credentials_repo.store_credentials(
                    test_data.component_id,
                    invalid_data
                )
                expect(result).to_be_nil()
                expect(err:match("Credentials data is required")).not_to_be_nil()
            end)
        end)

        describe("get_credentials", function()
            before_each(function()
                -- Create test credentials
                credentials_repo.store_credentials(test_data.component_id, test_connection_data)
            end)

            it("should retrieve complete credentials with metadata", function()
                local creds, err = credentials_repo.get_credentials(test_data.component_id)

                expect(err).to_be_nil()
                expect(creds).not_to_be_nil()

                -- Check connection metadata
                expect(creds.component_id).to_equal(test_data.component_id)
                expect(creds.connection_name).to_equal("My GitHub Connection")
                expect(creds.connection_description).to_equal("GitHub integration for development")

                -- Check decrypted credentials
                expect(creds.credentials).not_to_be_nil()
                expect(creds.credentials.api_key).to_equal("ghp_1234567890abcdef")
                expect(creds.credentials.access_token).to_equal("gho_16C7e42F292c6912E7710c838347Ae178B4a")
                expect(creds.credentials.client_secret).to_equal("super_secret_client_secret_456")
                expect(creds.credentials.username).to_equal("testuser")

                -- Check metadata
                expect(creds.metadata).not_to_be_nil()
                expect(creds.metadata.provider).to_equal("github")
                expect(creds.metadata.environment).to_equal("production")
                expect(creds.metadata.created_by).to_equal("test_user")

                expect(creds.created_at).not_to_be_nil()
                expect(creds.updated_at).not_to_be_nil()
            end)

            it("should fail with missing component_id", function()
                local creds, err = credentials_repo.get_credentials(nil)
                expect(creds).to_be_nil()
                expect(err:match("Component ID is required")).not_to_be_nil()
            end)

            it("should fail with empty component_id", function()
                local creds, err = credentials_repo.get_credentials("")
                expect(creds).to_be_nil()
                expect(err:match("Component ID is required")).not_to_be_nil()
            end)

            it("should fail with non-existent component_id", function()
                local creds, err = credentials_repo.get_credentials(uuid.v7())
                expect(creds).to_be_nil()
                expect(err:match("Credentials not found")).not_to_be_nil()
            end)
        end)

        describe("get_connection_metadata", function()
            before_each(function()
                credentials_repo.store_credentials(test_data.component_id, test_connection_data)
            end)

            it("should retrieve connection metadata without decryption", function()
                local metadata, err = credentials_repo.get_connection_metadata(test_data.component_id)

                expect(err).to_be_nil()
                expect(metadata).not_to_be_nil()

                -- Check public fields are present
                expect(metadata.component_id).to_equal(test_data.component_id)
                expect(metadata.connection_name).to_equal("My GitHub Connection")
                expect(metadata.connection_description).to_equal("GitHub integration for development")

                -- Check metadata is decoded
                expect(metadata.metadata).not_to_be_nil()
                expect(metadata.metadata.provider).to_equal("github")
                expect(metadata.metadata.environment).to_equal("production")

                -- Check encrypted fields are NOT present
                expect(metadata.credentials).to_be_nil()
                expect(metadata.credentials_data).to_be_nil()

                expect(metadata.created_at).not_to_be_nil()
                expect(metadata.updated_at).not_to_be_nil()
            end)

            it("should fail with non-existent component_id", function()
                local metadata, err = credentials_repo.get_connection_metadata(uuid.v7())
                expect(metadata).to_be_nil()
                expect(err:match("Connection not found")).not_to_be_nil()
            end)

            it("should fail with missing component_id", function()
                local metadata, err = credentials_repo.get_connection_metadata(nil)
                expect(metadata).to_be_nil()
                expect(err:match("Component ID is required")).not_to_be_nil()
            end)
        end)

        describe("delete_credentials", function()
            before_each(function()
                credentials_repo.store_credentials(test_data.component_id, test_connection_data)
            end)

            it("should delete credentials successfully", function()
                -- Verify credentials exist
                local creds, err = credentials_repo.get_credentials(test_data.component_id)
                expect(err).to_be_nil()
                expect(creds).not_to_be_nil()

                -- Delete credentials
                local result, err = credentials_repo.delete_credentials(test_data.component_id)

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()
                expect(result.component_id).to_equal(test_data.component_id)
                expect(result.success).to_be_true()
                expect(result.deleted).to_be_true()

                -- Verify credentials are gone
                creds, err = credentials_repo.get_credentials(test_data.component_id)
                expect(creds).to_be_nil()
                expect(err:match("Credentials not found")).not_to_be_nil()
            end)

            it("should fail with non-existent component_id", function()
                local result, err = credentials_repo.delete_credentials(uuid.v7())

                expect(result).to_be_nil()
                expect(err:match("Credentials not found")).not_to_be_nil()
            end)

            it("should fail with missing component_id", function()
                local result, err = credentials_repo.delete_credentials(nil)

                expect(result).to_be_nil()
                expect(err:match("Component ID is required")).not_to_be_nil()
            end)

            it("should fail with empty component_id", function()
                local result, err = credentials_repo.delete_credentials("")

                expect(result).to_be_nil()
                expect(err:match("Component ID is required")).not_to_be_nil()
            end)
        end)

        describe("encryption/decryption", function()
            it("should verify that credentials are actually encrypted in database", function()
                credentials_repo.store_credentials(test_data.component_id, test_connection_data)

                -- Query the database directly to verify data is encrypted
                local db, err = sql.get("app:db")
                expect(err).to_be_nil()

                local query = sql.builder.select("credentials_data")
                    :from("credentials_store")
                    :where("component_id = ?", test_data.component_id)

                local executor = query:run_with(db)
                local results, err = executor:query()

                db:release()

                expect(err).to_be_nil()
                expect(#results).to_equal(1)

                local raw_record = results[1]

                -- Verify the stored data is not in plain text
                expect(raw_record.credentials_data:find("ghp_1234567890abcdef", 1, true)).to_be_nil()
                expect(raw_record.credentials_data:find("gho_16C7e42F292c6912E7710c838347Ae178B4a", 1, true)).to_be_nil()
                expect(raw_record.credentials_data:find("super_secret_client_secret_456", 1, true)).to_be_nil()
                expect(raw_record.credentials_data:find("testuser", 1, true)).to_be_nil()
            end)

            it("should handle complex nested credential structures", function()
                local complex_credentials = {
                    oauth = {
                        access_token = "ya29.complex_access_token",
                        refresh_token = "1//04complex_refresh_token",
                        scopes = {"read", "write", "admin"},
                        expires_in = 3600
                    },
                    api_config = {
                        endpoints = {
                            users = "https://api.example.com/users",
                            repos = "https://api.example.com/repos"
                        },
                        rate_limits = {
                            core = 5000,
                            search = 30
                        }
                    },
                    secrets = {
                        webhook_secret = "super_secret_webhook_key",
                        private_key = "-----BEGIN PRIVATE KEY-----\nMIIEvQ..."
                    }
                }

                local complex_data = {
                    connection_name = "Complex API Connection",
                    credentials = complex_credentials,
                    metadata = {
                        provider = "complex_api",
                        type = "complex_test"
                    }
                }

                local result, err = credentials_repo.store_credentials(
                    test_data.component_id3,
                    complex_data
                )

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()

                -- Verify complex data retrieval
                local creds, err = credentials_repo.get_credentials(test_data.component_id3)
                expect(err).to_be_nil()
                expect(creds.credentials.oauth.access_token).to_equal("ya29.complex_access_token")
                expect(#creds.credentials.oauth.scopes).to_equal(3)
                expect(creds.credentials.oauth.scopes[1]).to_equal("read")
                expect(creds.credentials.api_config.rate_limits.core).to_equal(5000)
                expect(creds.credentials.secrets.webhook_secret).to_equal("super_secret_webhook_key")
            end)

            it("should handle empty credentials object", function()
                local empty_data = {
                    connection_name = "Empty Test Connection",
                    credentials = {},
                    metadata = {
                        provider = "empty_test",
                        type = "empty"
                    }
                }

                local result, err = credentials_repo.store_credentials(
                    test_data.component_id3,
                    empty_data
                )

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()

                -- Verify empty retrieval
                local creds, err = credentials_repo.get_credentials(test_data.component_id3)
                expect(err).to_be_nil()
                expect(creds.credentials).to_be_type("table")
                expect(creds.metadata.type).to_equal("empty")
            end)

            it("should handle credentials with special characters and encoding", function()
                local special_credentials = {
                    password_with_special_chars = "p@ssw0rd!#$%^&*(){}[]|\\:;\"'<>,.?/~`",
                    unicode_text = "こんにちは世界",
                    base64_data = "dGVzdCBkYXRhIGZvciBiYXNlNjQgZW5jb2Rpbmc=",
                    json_string = '{"nested": "json", "array": [1, 2, 3]}'
                }

                local special_data = {
                    connection_name = "Special Characters Test",
                    credentials = special_credentials,
                    metadata = {
                        provider = "special_test",
                        encoding = "utf-8"
                    }
                }

                local result, err = credentials_repo.store_credentials(
                    test_data.component_id2,
                    special_data
                )

                expect(err).to_be_nil()
                expect(result).not_to_be_nil()

                -- Verify special data retrieval
                local creds, err = credentials_repo.get_credentials(test_data.component_id2)
                expect(err).to_be_nil()
                expect(creds.credentials.password_with_special_chars).to_equal("p@ssw0rd!#$%^&*(){}[]|\\:;\"'<>,.?/~`")
                expect(creds.credentials.unicode_text).to_equal("こんにちは世界")
                expect(creds.credentials.base64_data).to_equal("dGVzdCBkYXRhIGZvciBiYXNlNjQgZW5jb2Rpbmc=")
                expect(creds.credentials.json_string).to_equal('{"nested": "json", "array": [1, 2, 3]}')
            end)
        end)
    end)
end

return test.run_cases(define_tests)