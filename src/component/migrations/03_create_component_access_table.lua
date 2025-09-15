return require("migration").define(function()
    migration("Create component_access table for bitmask-based permission control", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE component_access (
                        access_id UUID PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        component_id UUID NOT NULL,
                        access_mask INTEGER NOT NULL DEFAULT 0,
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        FOREIGN KEY (component_id) REFERENCES components(component_id) ON DELETE CASCADE,
                        UNIQUE(user_id, component_id)
                    )
                ]])

                if err then
                    error("Failed to create component_access table: " .. err)
                end

                -- Create indexes for efficient access checking
                success, err = db:execute("CREATE INDEX idx_component_access_user_id ON component_access(user_id)")
                if err then
                    error("Failed to create user_id index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_component_access_component_id ON component_access(component_id)")
                if err then
                    error("Failed to create component_id index: " .. err)
                end

                -- Composite index for fast permission lookups
                success, err = db:execute("CREATE INDEX idx_component_access_user_component ON component_access(user_id, component_id)")
                if err then
                    error("Failed to create user_component index: " .. err)
                end

                -- Index for access mask filtering
                success, err = db:execute("CREATE INDEX idx_component_access_mask ON component_access(access_mask)")
                if err then
                    error("Failed to create access_mask index: " .. err)
                end

                -- Composite index for user + mask queries (e.g., find all components user can write to)
                success, err = db:execute("CREATE INDEX idx_component_access_user_mask ON component_access(user_id, access_mask)")
                if err then
                    error("Failed to create user_mask index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_user_mask")
                if err then
                    error("Failed to drop user_mask index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_mask")
                if err then
                    error("Failed to drop access_mask index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_user_component")
                if err then
                    error("Failed to drop user_component index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_component_id")
                if err then
                    error("Failed to drop component_id index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_user_id")
                if err then
                    error("Failed to drop user_id index: " .. err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS component_access CASCADE")
                if err then
                    error("Failed to drop component_access table: " .. err)
                end

                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE component_access (
                        access_id TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        component_id TEXT NOT NULL,
                        access_mask INTEGER NOT NULL DEFAULT 0,
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        FOREIGN KEY (component_id) REFERENCES components(component_id) ON DELETE CASCADE,
                        UNIQUE(user_id, component_id)
                    )
                ]])

                if err then
                    error("Failed to create component_access table: " .. err)
                end

                -- Create indexes for efficient access checking
                success, err = db:execute("CREATE INDEX idx_component_access_user_id ON component_access(user_id)")
                if err then
                    error("Failed to create user_id index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_component_access_component_id ON component_access(component_id)")
                if err then
                    error("Failed to create component_id index: " .. err)
                end

                -- Composite index for fast permission lookups
                success, err = db:execute("CREATE INDEX idx_component_access_user_component ON component_access(user_id, component_id)")
                if err then
                    error("Failed to create user_component index: " .. err)
                end

                -- Index for access mask filtering
                success, err = db:execute("CREATE INDEX idx_component_access_mask ON component_access(access_mask)")
                if err then
                    error("Failed to create access_mask index: " .. err)
                end

                -- Composite index for user + mask queries (e.g., find all components user can write to)
                success, err = db:execute("CREATE INDEX idx_component_access_user_mask ON component_access(user_id, access_mask)")
                if err then
                    error("Failed to create user_mask index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_user_mask")
                if err then
                    error("Failed to drop user_mask index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_mask")
                if err then
                    error("Failed to drop access_mask index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_user_component")
                if err then
                    error("Failed to drop user_component index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_component_id")
                if err then
                    error("Failed to drop component_id index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_access_user_id")
                if err then
                    error("Failed to drop user_id index: " .. err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS component_access")
                if err then
                    error("Failed to drop component_access table: " .. err)
                end

                return true
            end)
        end)
    end)
end)