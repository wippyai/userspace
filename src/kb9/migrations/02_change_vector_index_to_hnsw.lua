return require("migration").define(function()
    migration("Change kb_embeddings vector index from ivfflat to hnsw", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    DROP INDEX IF EXISTS idx_kb_embeddings_vector;
                ]])
                if err then error("Failed to drop old vector index: " .. err) end

                _, err = db:execute([[
                    CREATE INDEX idx_kb_embeddings_vector ON kb_node_embeddings
                    USING hnsw (embedding vector_cosine_ops)
                    WITH (m = 16, ef_construction = 64);
                ]])
                if err then error("Failed to create HNSW vector index: " .. err) end

                return true
            end)

            down(function(db)
                local _, err = db:execute([[
                    DROP INDEX IF EXISTS idx_kb_embeddings_vector;
                ]])
                if err then error("Failed to drop HNSW vector index: " .. err) end

                _, err = db:execute([[
                    CREATE INDEX idx_kb_embeddings_vector ON kb_node_embeddings
                    USING ivfflat (embedding vector_cosine_ops)
                    WITH (lists = 100);
                ]])
                if err then error("Failed to recreate ivfflat vector index: " .. err) end

                return true
            end)
        end)

        database("sqlite", function()
            up(function(db)
                return true
            end)

            down(function(db)
                return true
            end)
        end)
    end)
end)
