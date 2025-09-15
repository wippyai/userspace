return require("migration").define(function()
    migration("Create knowledge base tables", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                local success, err = db:execute("CREATE EXTENSION IF NOT EXISTS vector;")
                if err then error("Failed to create vector extension: " .. err) end

                success, err = db:execute([[
                    CREATE TABLE kb_components (
                        id UUID PRIMARY KEY,
                        component_id UUID NOT NULL UNIQUE,
                        config JSONB NOT NULL DEFAULT '{}',
                        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                        updated_at TIMESTAMP NOT NULL DEFAULT NOW()
                    );
                ]])
                if err then error("Failed to create kb_components: " .. err) end

                success, err = db:execute([[
                    CREATE TABLE kb_nodes (
                        id UUID PRIMARY KEY,
                        kb_id UUID NOT NULL REFERENCES kb_components(id) ON DELETE CASCADE,
                        parent_id UUID REFERENCES kb_nodes(id) ON DELETE CASCADE,
                        path TEXT NOT NULL,
                        node_type TEXT NOT NULL,
                        content TEXT,
                        content_type TEXT,
                        value TEXT,
                        metadata JSONB DEFAULT '{}',
                        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                        updated_at TIMESTAMP NOT NULL DEFAULT NOW()
                    );
                ]])
                if err then error("Failed to create kb_nodes: " .. err) end

                success, err = db:execute([[
                    CREATE TABLE kb_node_embeddings (
                        id UUID PRIMARY KEY,
                        node_id UUID NOT NULL REFERENCES kb_nodes(id) ON DELETE CASCADE,
                        kb_id UUID NOT NULL REFERENCES kb_components(id) ON DELETE CASCADE,
                        model_name TEXT NOT NULL DEFAULT 'default',
                        embedding vector(512) NOT NULL,
                        created_at TIMESTAMP NOT NULL DEFAULT NOW(),

                        UNIQUE(node_id, model_name)
                    );
                ]])
                if err then error("Failed to create kb_node_embeddings: " .. err) end

                success, err = db:execute([[
                    ALTER TABLE kb_nodes ADD COLUMN
                    search_vector tsvector GENERATED ALWAYS AS (
                        setweight(to_tsvector('english', coalesce(content, '')), 'A') ||
                        setweight(to_tsvector('english', coalesce(node_type, '')), 'B')
                    ) STORED;
                ]])
                if err then error("Failed to add search vector: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_value ON kb_nodes (kb_id, value);
                ]])
                if err then error("Failed to create value index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_value_type ON kb_nodes (kb_id, value, node_type);
                ]])
                if err then error("Failed to create value/type compound index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_parent ON kb_nodes (kb_id, parent_id);
                ]])
                if err then error("Failed to create parent index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_path ON kb_nodes USING btree (kb_id, path text_pattern_ops);
                ]])
                if err then error("Failed to create path index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_type ON kb_nodes (kb_id, node_type);
                ]])
                if err then error("Failed to create type index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_fts ON kb_nodes USING GIN (search_vector);
                ]])
                if err then error("Failed to create FTS index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_embeddings_node ON kb_node_embeddings (node_id);
                ]])
                if err then error("Failed to create embeddings node index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_embeddings_kb ON kb_node_embeddings (kb_id);
                ]])
                if err then error("Failed to create embeddings kb index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_embeddings_type ON kb_node_embeddings (kb_id, model_name);
                ]])
                if err then error("Failed to create embeddings type index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_embeddings_vector ON kb_node_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
                ]])
                if err then error("Failed to create vector index: " .. err) end

                return true
            end)

            down(function(db)
                db:execute("DROP TABLE IF EXISTS kb_node_embeddings CASCADE;")
                db:execute("DROP TABLE IF EXISTS kb_nodes CASCADE;")
                db:execute("DROP TABLE IF EXISTS kb_components CASCADE;")
                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE kb_components (
                        id TEXT PRIMARY KEY,
                        component_id TEXT NOT NULL UNIQUE,
                        config TEXT NOT NULL DEFAULT '{}',
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    );
                ]])
                if err then error("Failed to create kb_components: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_component_id ON kb_components(component_id);
                ]])
                if err then error("Failed to create component_id index: " .. err) end

                success, err = db:execute([[
                    CREATE TABLE kb_nodes (
                        id TEXT PRIMARY KEY,
                        kb_id TEXT NOT NULL REFERENCES kb_components(id) ON DELETE CASCADE,
                        parent_id TEXT REFERENCES kb_nodes(id) ON DELETE CASCADE,
                        path TEXT NOT NULL,
                        node_type TEXT NOT NULL,
                        content TEXT,
                        content_type TEXT,
                        value TEXT,
                        metadata TEXT DEFAULT '{}',
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    );
                ]])
                if err then error("Failed to create kb_nodes: " .. err) end

                success, err = db:execute([[
                    CREATE VIRTUAL TABLE kb_node_embeddings USING vec0(
                        id TEXT PRIMARY KEY,
                        node_id TEXT,
                        kb_id TEXT PARTITION KEY,
                        model_name TEXT,
                        node_type TEXT,
                        parent_id TEXT,
                        path TEXT,
                        content_type TEXT,
                        created_at INTEGER,
                        embedding float[512]
                    );
                ]])
                if err then error("Failed to create kb_node_embeddings: " .. err) end

                success, err = db:execute([[
                    CREATE VIRTUAL TABLE kb_nodes_fts USING fts5(
                        node_id UNINDEXED,
                        content,
                        node_type,
                        tokenize = 'porter'
                    );
                ]])
                if err then error("Failed to create FTS table: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_value ON kb_nodes(kb_id, value);
                ]])
                if err then error("Failed to create value index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_parent ON kb_nodes(kb_id, parent_id);
                ]])
                if err then error("Failed to create parent index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_path ON kb_nodes(kb_id, path);
                ]])
                if err then error("Failed to create path index: " .. err) end

                success, err = db:execute([[
                    CREATE INDEX idx_kb_nodes_type ON kb_nodes(kb_id, node_type);
                ]])
                if err then error("Failed to create type index: " .. err) end

                return true
            end)

            down(function(db)
                db:execute("DROP TABLE IF EXISTS kb_nodes_fts;")
                db:execute("DROP TABLE IF EXISTS kb_node_embeddings;")
                db:execute("DROP TABLE IF EXISTS kb_nodes;")
                db:execute("DROP TABLE IF EXISTS kb_components;")
                return true
            end)
        end)
    end)
end)