return require("migration").define(function()
    migration("Add type_id to uploads table", function()
        database("postgres", function()
            up(function(db)
                -- Add type_id column to uploads table
                local success, err = db:execute([[
                    ALTER TABLE uploads
                    ADD COLUMN type_id TEXT
                ]])

                if err then
                    error(err)
                end

                -- Create index for type_id
                success, err = db:execute("CREATE INDEX idx_uploads_type ON uploads(type_id)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop index first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_uploads_type")
                if err then
                    error(err)
                end

                -- SQLite doesn't support dropping columns directly,
                -- so we'd need to recreate the table without the column.
                -- For simplicity in this example, we'll just note this limitation.
                error("SQLite doesn't support dropping columns. Manual table recreation required.")
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Add type_id column to uploads table
                local success, err = db:execute([[
                    ALTER TABLE uploads
                    ADD COLUMN type_id TEXT
                ]])

                if err then
                    error(err)
                end

                -- Create index for type_id
                success, err = db:execute("CREATE INDEX idx_uploads_type ON uploads(type_id)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                -- Drop index first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_uploads_type")
                if err then
                    error(err)
                end

                -- SQLite doesn't support dropping columns directly,
                -- so we'd need to recreate the table without the column.
                -- For simplicity in this example, we'll just note this limitation.
                error("SQLite doesn't support dropping columns. Manual table recreation required.")
            end)
        end)
    end)
end)
