return require("migration").define(function()
    migration("Create kb_embed_operations table for async upload tracking", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE kb_embed_operations (
                        id UUID PRIMARY KEY,
                        component_id UUID NOT NULL,
                        upload_uuid TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'processing',
                        error TEXT,
                        ops_executed INTEGER NOT NULL DEFAULT 0,
                        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                        updated_at TIMESTAMP NOT NULL DEFAULT NOW()
                    );
                ]])
                if err then error("Failed to create kb_embed_operations: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_embed_operations_component
                    ON kb_embed_operations (component_id);
                ]])
                if err then error("Failed to create component_id index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_embed_operations_component_status
                    ON kb_embed_operations (component_id, status);
                ]])
                if err then error("Failed to create component_id/status index: " .. err) end

                return true
            end)

            down(function(db)
                db:execute("DROP TABLE IF EXISTS kb_embed_operations;")
                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE kb_embed_operations (
                        id TEXT PRIMARY KEY,
                        component_id TEXT NOT NULL,
                        upload_uuid TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'processing',
                        error TEXT,
                        ops_executed INTEGER NOT NULL DEFAULT 0,
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    );
                ]])
                if err then error("Failed to create kb_embed_operations: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_embed_operations_component
                    ON kb_embed_operations (component_id);
                ]])
                if err then error("Failed to create component_id index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_embed_operations_component_status
                    ON kb_embed_operations (component_id, status);
                ]])
                if err then error("Failed to create component_id/status index: " .. err) end

                return true
            end)

            down(function(db)
                db:execute("DROP TABLE IF EXISTS kb_embed_operations;")
                return true
            end)
        end)
    end)
end)
