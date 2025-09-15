return require("migration").define(function()
    migration("Create components table for user component registry", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE components (
                        component_id UUID PRIMARY KEY,
                        impl_id TEXT NOT NULL,
                        private_context JSONB DEFAULT '{}',
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        updated_at TIMESTAMP NOT NULL DEFAULT now()
                    )
                ]])

                if err then
                    error("Failed to create components table: " .. err)
                end

                -- Create indexes for efficient querying
                success, err = db:execute("CREATE INDEX idx_components_impl_id ON components(impl_id)")
                if err then
                    error("Failed to create impl_id index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_created_at ON components(created_at)")
                if err then
                    error("Failed to create created_at index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_updated_at ON components(updated_at)")
                if err then
                    error("Failed to create updated_at index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_components_updated_at")
                if err then
                    error("Failed to drop updated_at index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_components_created_at")
                if err then
                    error("Failed to drop created_at index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_components_impl_id")
                if err then
                    error("Failed to drop impl_id index: " .. err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS components CASCADE")
                if err then
                    error("Failed to drop components table: " .. err)
                end

                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE components (
                        component_id TEXT PRIMARY KEY,
                        impl_id TEXT NOT NULL,
                        private_context TEXT DEFAULT '{}',
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    )
                ]])

                if err then
                    error("Failed to create components table: " .. err)
                end

                -- Create indexes for efficient querying
                success, err = db:execute("CREATE INDEX idx_components_impl_id ON components(impl_id)")
                if err then
                    error("Failed to create impl_id index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_created_at ON components(created_at)")
                if err then
                    error("Failed to create created_at index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_updated_at ON components(updated_at)")
                if err then
                    error("Failed to create updated_at index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_components_updated_at")
                if err then
                    error("Failed to drop updated_at index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_components_created_at")
                if err then
                    error("Failed to drop created_at index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_components_impl_id")
                if err then
                    error("Failed to drop impl_id index: " .. err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS components")
                if err then
                    error("Failed to drop components table: " .. err)
                end

                return true
            end)
        end)
    end)
end)
