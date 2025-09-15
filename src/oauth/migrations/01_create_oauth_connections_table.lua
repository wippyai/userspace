return require("migration").define(function()
    migration("Create oauth_connections table for OAuth connection and token storage", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                -- Create the OAuth connections table
                local success, err = db:execute([[
                    CREATE TABLE oauth_connections (
                        id UUID PRIMARY KEY,
                        component_id UUID NOT NULL UNIQUE,
                        provider VARCHAR(100) NOT NULL,
                        connection_name VARCHAR(255) NOT NULL,
                        connection_description TEXT,
                        schedule_id UUID,

                        -- OAuth metadata (unencrypted for querying)
                        scopes_granted TEXT,
                        connection_state VARCHAR(50) DEFAULT 'active',
                        token_type VARCHAR(50) DEFAULT 'Bearer',
                        expires_at BIGINT,
                        refresh_expires_at BIGINT,

                        -- Optimized access token storage (encrypted)
                        access_token_encrypted TEXT,

                        -- All sensitive OAuth data (encrypted JSON blob)
                        oauth_data_encrypted TEXT NOT NULL,

                        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                        updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                        last_token_refresh TIMESTAMP
                    );
                ]])

                if err then
                    error("Failed to create oauth_connections table: " .. err)
                end

                -- Create indexes for efficient querying
                success, err = db:execute([[
                    CREATE INDEX idx_oauth_connections_component_id ON oauth_connections(component_id);
                ]])

                if err then
                    error("Failed to create component_id index: " .. err)
                end

                success, err = db:execute([[
                    CREATE INDEX idx_oauth_connections_provider ON oauth_connections(provider);
                ]])

                if err then
                    error("Failed to create provider index: " .. err)
                end

                success, err = db:execute([[
                    CREATE INDEX idx_oauth_connections_schedule_id ON oauth_connections(schedule_id) WHERE schedule_id IS NOT NULL;
                ]])

                if err then
                    error("Failed to create schedule_id index: " .. err)
                end

                success, err = db:execute([[
                    CREATE INDEX idx_oauth_connections_expires_at ON oauth_connections(expires_at) WHERE expires_at IS NOT NULL;
                ]])

                if err then
                    error("Failed to create expiration index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop the table and indexes
                local success, err = db:execute([[
                    DROP TABLE IF EXISTS oauth_connections CASCADE;
                ]])

                if err then
                    error("Failed to drop oauth_connections table: " .. err)
                end

                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                -- Create the OAuth connections table
                local success, err = db:execute([[
                    CREATE TABLE oauth_connections (
                        id TEXT PRIMARY KEY,
                        component_id TEXT NOT NULL UNIQUE,
                        provider TEXT NOT NULL,
                        connection_name TEXT NOT NULL,
                        connection_description TEXT,
                        schedule_id TEXT,

                        -- OAuth metadata (unencrypted for querying)
                        scopes_granted TEXT,
                        connection_state TEXT DEFAULT 'active',
                        token_type TEXT DEFAULT 'Bearer',
                        expires_at INTEGER,
                        refresh_expires_at INTEGER,

                        -- Optimized access token storage (encrypted)
                        access_token_encrypted TEXT,

                        -- All sensitive OAuth data (encrypted JSON blob)
                        oauth_data_encrypted TEXT NOT NULL,

                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL,
                        last_token_refresh TEXT
                    )
                ]])

                if err then
                    error("Failed to create oauth_connections table: " .. err)
                end

                -- Create indexes for efficient querying
                success, err = db:execute([[
                    CREATE INDEX idx_oauth_connections_component_id ON oauth_connections(component_id);
                ]])

                if err then
                    error("Failed to create component_id index: " .. err)
                end

                success, err = db:execute([[
                    CREATE INDEX idx_oauth_connections_provider ON oauth_connections(provider);
                ]])

                if err then
                    error("Failed to create provider index: " .. err)
                end

                success, err = db:execute([[
                    CREATE INDEX idx_oauth_connections_schedule_id ON oauth_connections(schedule_id) WHERE schedule_id IS NOT NULL;
                ]])

                if err then
                    error("Failed to create schedule_id index: " .. err)
                end

                success, err = db:execute([[
                    CREATE INDEX idx_oauth_connections_expires_at ON oauth_connections(expires_at) WHERE expires_at IS NOT NULL;
                ]])

                if err then
                    error("Failed to create expiration index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop the table
                local success, err = db:execute([[
                    DROP TABLE IF EXISTS oauth_connections;
                ]])

                if err then
                    error("Failed to drop oauth_connections table: " .. err)
                end

                return true
            end)
        end)
    end)
end)