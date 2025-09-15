return require("migration").define(function()
    migration("Create content storage table", function()
        database("postgres", function()
            up(function(db)
                -- Create content table
                local success, err = db:execute([[
                    CREATE TABLE upload_content (
                        content_id TEXT PRIMARY KEY,
                        upload_id TEXT NOT NULL,
                        mime_type TEXT NOT NULL,
                        content bytea,
                        metadata TEXT,
                        created_at timestamp NOT NULL DEFAULT now(), -- Unix timestamp (seconds since 1970-01-01)
                        updated_at timestamp NOT NULL DEFAULT now(), -- Unix timestamp (seconds since 1970-01-01)
                        FOREIGN KEY (upload_id) REFERENCES uploads(uuid) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes
                success, err = db:execute("CREATE INDEX idx_content_upload ON upload_content(upload_id)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_content_mime ON upload_content(mime_type)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_content_upload")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_content_mime")
                if err then
                    error(err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS upload_content")
                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Create content table
                local success, err = db:execute([[
                    CREATE TABLE upload_content (
                        content_id TEXT PRIMARY KEY,
                        upload_id TEXT NOT NULL,
                        mime_type TEXT NOT NULL,
                        content BLOB,
                        metadata TEXT,
                        created_at INTEGER NOT NULL, -- Unix timestamp (seconds since 1970-01-01)
                        updated_at INTEGER NOT NULL, -- Unix timestamp (seconds since 1970-01-01)
                        FOREIGN KEY (upload_id) REFERENCES uploads(uuid) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes
                success, err = db:execute("CREATE INDEX idx_content_upload ON upload_content(upload_id)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_content_mime ON upload_content(mime_type)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_content_upload")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_content_mime")
                if err then
                    error(err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS upload_content")
                if err then
                    error(err)
                end
            end)
        end)
    end)
end)