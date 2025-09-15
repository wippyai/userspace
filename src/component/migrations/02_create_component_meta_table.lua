return require("migration").define(function()
    migration("Create component_meta table for flexible key-value metadata storage", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE component_meta (
                        meta_id UUID PRIMARY KEY,
                        component_id UUID NOT NULL,
                        key TEXT NOT NULL,
                        value TEXT,
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        updated_at TIMESTAMP NOT NULL DEFAULT now(),
                        FOREIGN KEY (component_id) REFERENCES components(component_id) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error("Failed to create component_meta table: " .. err)
                end

                -- Create indexes for efficient querying
                success, err = db:execute("CREATE INDEX idx_component_meta_component_id ON component_meta(component_id)")
                if err then
                    error("Failed to create component_id index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_component_meta_key ON component_meta(key)")
                if err then
                    error("Failed to create key index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_component_meta_value ON component_meta(value)")
                if err then
                    error("Failed to create value index: " .. err)
                end

                -- Composite index for efficient key-value lookups
                success, err = db:execute("CREATE INDEX idx_component_meta_key_value ON component_meta(key, value)")
                if err then
                    error("Failed to create key_value index: " .. err)
                end

                -- Composite index for component-specific meta lookups
                success, err = db:execute("CREATE INDEX idx_component_meta_component_key ON component_meta(component_id, key)")
                if err then
                    error("Failed to create component_key index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_component_key")
                if err then
                    error("Failed to drop component_key index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_key_value")
                if err then
                    error("Failed to drop key_value index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_value")
                if err then
                    error("Failed to drop value index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_key")
                if err then
                    error("Failed to drop key index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_component_id")
                if err then
                    error("Failed to drop component_id index: " .. err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS component_meta CASCADE")
                if err then
                    error("Failed to drop component_meta table: " .. err)
                end

                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE component_meta (
                        meta_id TEXT PRIMARY KEY,
                        component_id TEXT NOT NULL,
                        key TEXT NOT NULL,
                        value TEXT,
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        FOREIGN KEY (component_id) REFERENCES components(component_id) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error("Failed to create component_meta table: " .. err)
                end

                -- Create indexes for efficient querying
                success, err = db:execute("CREATE INDEX idx_component_meta_component_id ON component_meta(component_id)")
                if err then
                    error("Failed to create component_id index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_component_meta_key ON component_meta(key)")
                if err then
                    error("Failed to create key index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_component_meta_value ON component_meta(value)")
                if err then
                    error("Failed to create value index: " .. err)
                end

                -- Composite index for efficient key-value lookups
                success, err = db:execute("CREATE INDEX idx_component_meta_key_value ON component_meta(key, value)")
                if err then
                    error("Failed to create key_value index: " .. err)
                end

                -- Composite index for component-specific meta lookups
                success, err = db:execute("CREATE INDEX idx_component_meta_component_key ON component_meta(component_id, key)")
                if err then
                    error("Failed to create component_key index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_component_key")
                if err then
                    error("Failed to drop component_key index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_key_value")
                if err then
                    error("Failed to drop key_value index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_value")
                if err then
                    error("Failed to drop value index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_key")
                if err then
                    error("Failed to drop key index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_component_meta_component_id")
                if err then
                    error("Failed to drop component_id index: " .. err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS component_meta")
                if err then
                    error("Failed to drop component_meta table: " .. err)
                end

                return true
            end)
        end)
    end)
end)