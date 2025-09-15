return require("migration").define(function()
    migration("Create user_auth_tokens table for token storage", function()
        database("postgres", function()
            up(function(db)
                -- Create user_auth_tokens table for SQL-based token store
                local success, err = db:execute([[
                    CREATE TABLE user_auth_tokens (
                        token_key TEXT PRIMARY KEY,
                        token_value BYTEA NOT NULL,
                        expires_at TIMESTAMP,
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        updated_at TIMESTAMP NOT NULL DEFAULT now()
                    )
                ]])
                if err then error("Failed to create user_auth_tokens table: " .. err) end

                -- Create indexes for user_auth_tokens
                success, err = db:execute("CREATE INDEX idx_user_auth_tokens_expires_at ON user_auth_tokens(expires_at)")
                if err then error("Failed to create expires_at index: " .. err) end

                success, err = db:execute("CREATE INDEX idx_user_auth_tokens_created_at ON user_auth_tokens(created_at DESC)")
                if err then error("Failed to create created_at index: " .. err) end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_user_auth_tokens_created_at")
                if err then error("Failed to drop created_at index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_user_auth_tokens_expires_at")
                if err then error("Failed to drop expires_at index: " .. err) end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS user_auth_tokens")
                if err then error("Failed to drop user_auth_tokens table: " .. err) end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Create user_auth_tokens table for SQL-based token store
                local success, err = db:execute([[
                    CREATE TABLE user_auth_tokens (
                        token_key TEXT PRIMARY KEY,
                        token_value BLOB NOT NULL,
                        expires_at INTEGER,
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    )
                ]])
                if err then error("Failed to create user_auth_tokens table: " .. err) end

                -- Create indexes for user_auth_tokens
                success, err = db:execute("CREATE INDEX idx_user_auth_tokens_expires_at ON user_auth_tokens(expires_at)")
                if err then error("Failed to create expires_at index: " .. err) end

                success, err = db:execute("CREATE INDEX idx_user_auth_tokens_created_at ON user_auth_tokens(created_at DESC)")
                if err then error("Failed to create created_at index: " .. err) end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_user_auth_tokens_created_at")
                if err then error("Failed to drop created_at index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_user_auth_tokens_expires_at")
                if err then error("Failed to drop expires_at index: " .. err) end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS user_auth_tokens")
                if err then error("Failed to drop user_auth_tokens table: " .. err) end
            end)
        end)
    end)
end)