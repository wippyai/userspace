return require("migration").define(function()
    migration("Add actor and scope columns to schedules table", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                -- Add actor columns
                local success, err = db:execute([[
                    ALTER TABLE schedules
                    ADD COLUMN actor_id TEXT,
                    ADD COLUMN actor_scope TEXT,
                    ADD COLUMN actor_metadata JSONB DEFAULT '{}'
                ]])

                if err then
                    error("Failed to add actor columns to schedules table: " .. err)
                end

                -- Add index for actor queries
                success, err = db:execute([[
                    CREATE INDEX idx_schedules_actor_id
                    ON schedules(actor_id)
                    WHERE actor_id IS NOT NULL
                ]])

                if err then
                    error("Failed to create actor_id index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- Drop index first
                local success, err = db:execute("DROP INDEX IF EXISTS idx_schedules_actor_id")
                if err then
                    error("Failed to drop actor_id index: " .. err)
                end

                -- Drop columns
                success, err = db:execute([[
                    ALTER TABLE schedules
                    DROP COLUMN IF EXISTS actor_metadata,
                    DROP COLUMN IF EXISTS actor_scope,
                    DROP COLUMN IF EXISTS actor_id
                ]])

                if err then
                    error("Failed to drop actor columns: " .. err)
                end

                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                -- Add actor columns
                local success, err = db:execute([[
                    ALTER TABLE schedules ADD COLUMN actor_id TEXT
                ]])

                if err then
                    error("Failed to add actor_id column: " .. err)
                end

                success, err = db:execute([[
                    ALTER TABLE schedules ADD COLUMN actor_scope TEXT
                ]])

                if err then
                    error("Failed to add actor_scope column: " .. err)
                end

                success, err = db:execute([[
                    ALTER TABLE schedules ADD COLUMN actor_metadata TEXT DEFAULT '{}'
                ]])

                if err then
                    error("Failed to add actor_metadata column: " .. err)
                end

                -- Add index for actor queries
                success, err = db:execute([[
                    CREATE INDEX idx_schedules_actor_id ON schedules(actor_id)
                ]])

                if err then
                    error("Failed to create actor_id index: " .. err)
                end

                return true
            end)

            down(function(db)
                -- SQLite doesn't support DROP COLUMN easily, so we'd need to recreate the table
                -- For now, just drop the index
                local success, err = db:execute("DROP INDEX IF EXISTS idx_schedules_actor_id")
                if err then
                    error("Failed to drop actor_id index: " .. err)
                end

                -- Note: SQLite doesn't easily support dropping columns
                -- In production, you might want to recreate the table without these columns
                print("Warning: SQLite columns actor_id, actor_scope, actor_metadata not dropped (SQLite limitation)")

                return true
            end)
        end)
    end)
end)