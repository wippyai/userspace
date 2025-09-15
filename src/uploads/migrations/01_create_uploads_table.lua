return require("migration").define(function()
    migration("Create uploads table", function()
        database("postgres", function()
            up(function(db)
                -- Create uploads table
                local success, err = db:execute([[
                    CREATE TABLE uploads (
                        uuid TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        size INTEGER NOT NULL,
                        mime_type TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'uploaded',
                        storage_id TEXT NOT NULL,
                        storage_path TEXT NOT NULL,
                        created_at timestamp NOT NULL DEFAULT now(),
                        updated_at timestamp NOT NULL DEFAULT now(),
                        error_details TEXT,
                        metadata TEXT,
                        FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE SET NULL (user_id)
                    );
                ]])

                if err then
                    error(err)
                end

                -- Create indexes
                success, err = db:execute("CREATE INDEX idx_uploads_user ON uploads(user_id)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_uploads_status ON uploads(status)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_uploads_created ON uploads(created_at)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_uploads_user")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_uploads_status")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_uploads_created")
                if err then
                    error(err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS uploads")
                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Create uploads table
                local success, err = db:execute([[
                    CREATE TABLE uploads (
                        uuid TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        size INTEGER NOT NULL,
                        mime_type TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'uploaded',
                        storage_id TEXT NOT NULL,
                        storage_path TEXT NOT NULL,
                        created_at INTEGER NOT NULL, -- Unix timestamp (seconds since 1970-01-01)
                        updated_at INTEGER NOT NULL, -- Unix timestamp (seconds since 1970-01-01)
                        error_details TEXT,
                        metadata TEXT,
                        FOREIGN KEY (user_id) REFERENCES users(user_id)
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes
                success, err = db:execute("CREATE INDEX idx_uploads_user ON uploads(user_id)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_uploads_status ON uploads(status)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_uploads_created ON uploads(created_at)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop indexes first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_uploads_user")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_uploads_status")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_uploads_created")
                if err then
                    error(err)
                end

                -- Drop table
                success, err = db:execute("DROP TABLE IF EXISTS uploads")
                if err then
                    error(err)
                end
            end)
        end)
    end)
end)
