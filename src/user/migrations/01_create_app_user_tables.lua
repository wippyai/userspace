return require("migration").define(function()
    migration("Create app_users and app_user_groups tables", function()
        database("postgres", function()
            up(function(db)
                -- Create app_users table
                local success, err = db:execute([[
                    CREATE TABLE app_users (
                        user_id TEXT PRIMARY KEY,
                        email TEXT UNIQUE NOT NULL,
                        full_name TEXT,
                        password_hash TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'active',
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        updated_at TIMESTAMP NOT NULL DEFAULT now()
                    )
                ]])
                if err then error("Failed to create app_users table: " .. err) end

                -- Create indexes for app_users
                success, err = db:execute("CREATE INDEX idx_app_users_email ON app_users(email)")
                if err then error("Failed to create email index: " .. err) end

                success, err = db:execute("CREATE INDEX idx_app_users_status ON app_users(status)")
                if err then error("Failed to create status index: " .. err) end

                success, err = db:execute("CREATE INDEX idx_app_users_created_at ON app_users(created_at DESC)")
                if err then error("Failed to create created_at index: " .. err) end

                -- Create app_user_groups table (association table)
                success, err = db:execute([[
                    CREATE TABLE app_user_groups (
                        user_id TEXT NOT NULL,
                        group_id TEXT NOT NULL,
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        PRIMARY KEY (user_id, group_id),
                        FOREIGN KEY (user_id) REFERENCES app_users(user_id) ON DELETE CASCADE
                    )
                ]])
                if err then error("Failed to create app_user_groups table: " .. err) end

                -- Create indexes for app_user_groups
                success, err = db:execute("CREATE INDEX idx_app_user_groups_user_id ON app_user_groups(user_id)")
                if err then error("Failed to create user_id index: " .. err) end

                success, err = db:execute("CREATE INDEX idx_app_user_groups_group_id ON app_user_groups(group_id)")
                if err then error("Failed to create group_id index: " .. err) end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_app_user_groups_group_id")
                if err then error("Failed to drop group_id index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_app_user_groups_user_id")
                if err then error("Failed to drop user_id index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_app_users_created_at")
                if err then error("Failed to drop created_at index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_app_users_status")
                if err then error("Failed to drop status index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_app_users_email")
                if err then error("Failed to drop email index: " .. err) end

                -- Drop tables
                success, err = db:execute("DROP TABLE IF EXISTS app_user_groups")
                if err then error("Failed to drop app_user_groups table: " .. err) end

                success, err = db:execute("DROP TABLE IF EXISTS app_users")
                if err then error("Failed to drop app_users table: " .. err) end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Create app_users table
                local success, err = db:execute([[
                    CREATE TABLE app_users (
                        user_id TEXT PRIMARY KEY,
                        email TEXT UNIQUE NOT NULL,
                        full_name TEXT,
                        password_hash TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'active',
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    )
                ]])
                if err then error("Failed to create app_users table: " .. err) end

                -- Create indexes for app_users
                success, err = db:execute("CREATE INDEX idx_app_users_email ON app_users(email)")
                if err then error("Failed to create email index: " .. err) end

                success, err = db:execute("CREATE INDEX idx_app_users_status ON app_users(status)")
                if err then error("Failed to create status index: " .. err) end

                success, err = db:execute("CREATE INDEX idx_app_users_created_at ON app_users(created_at DESC)")
                if err then error("Failed to create created_at index: " .. err) end

                -- Create app_user_groups table (association table)
                success, err = db:execute([[
                    CREATE TABLE app_user_groups (
                        user_id TEXT NOT NULL,
                        group_id TEXT NOT NULL,
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        PRIMARY KEY (user_id, group_id),
                        FOREIGN KEY (user_id) REFERENCES app_users(user_id) ON DELETE CASCADE
                    )
                ]])
                if err then error("Failed to create app_user_groups table: " .. err) end

                -- Create indexes for app_user_groups
                success, err = db:execute("CREATE INDEX idx_app_user_groups_user_id ON app_user_groups(user_id)")
                if err then error("Failed to create user_id index: " .. err) end

                success, err = db:execute("CREATE INDEX idx_app_user_groups_group_id ON app_user_groups(group_id)")
                if err then error("Failed to create group_id index: " .. err) end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_app_user_groups_group_id")
                if err then error("Failed to drop group_id index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_app_user_groups_user_id")
                if err then error("Failed to drop user_id index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_app_users_created_at")
                if err then error("Failed to drop created_at index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_app_users_status")
                if err then error("Failed to drop status index: " .. err) end

                success, err = db:execute("DROP INDEX IF EXISTS idx_app_users_email")
                if err then error("Failed to drop email index: " .. err) end

                -- Drop tables
                success, err = db:execute("DROP TABLE IF EXISTS app_user_groups")
                if err then error("Failed to drop app_user_groups table: " .. err) end

                success, err = db:execute("DROP TABLE IF EXISTS app_users")
                if err then error("Failed to drop app_users table: " .. err) end
            end)
        end)
    end)
end)