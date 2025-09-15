return require("migration").define(function()
    migration("Create credentials_store table for encrypted credential storage", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                -- Create the credentials store table
                local success, err = db:execute([[
                    CREATE TABLE credentials_store (
                        id UUID PRIMARY KEY,
                        component_id UUID NOT NULL UNIQUE,
                        connection_name VARCHAR(255) NOT NULL,
                        connection_description TEXT,
                        credentials_data TEXT NOT NULL,
                        metadata JSONB,
                        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                        updated_at TIMESTAMP NOT NULL DEFAULT NOW()
                    );
                ]])

                if err then
                    error("Failed to create credentials_store table: " .. err)
                end

                -- Create index for efficient lookups
                success, err = db:execute([[
                    CREATE INDEX idx_credentials_store_component_id ON credentials_store(component_id);
                ]])

                if err then
                    error("Failed to create component_id index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop the table and indexes
                local success, err = db:execute([[
                    DROP TABLE IF EXISTS credentials_store CASCADE;
                ]])

                if err then
                    error("Failed to drop credentials_store table: " .. err)
                end

                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                -- Create the credentials store table
                local success, err = db:execute([[
                    CREATE TABLE credentials_store (
                        id TEXT PRIMARY KEY,
                        component_id TEXT NOT NULL UNIQUE,
                        connection_name TEXT NOT NULL,
                        connection_description TEXT,
                        credentials_data TEXT NOT NULL,
                        metadata TEXT,
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL
                    )
                ]])

                if err then
                    error("Failed to create credentials_store table: " .. err)
                end

                -- Create index for efficient lookups
                success, err = db:execute([[
                    CREATE INDEX idx_credentials_store_component_id ON credentials_store(component_id);
                ]])

                if err then
                    error("Failed to create component_id index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop the table
                local success, err = db:execute([[
                    DROP TABLE IF EXISTS credentials_store;
                ]])

                if err then
                    error("Failed to drop credentials_store table: " .. err)
                end

                return true
            end)
        end)
    end)
end)