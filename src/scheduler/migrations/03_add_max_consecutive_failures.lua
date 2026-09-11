return require("migration").define(function()
    migration("Add max_consecutive_failures to schedules table", function()
        database("postgres", function()
            up(function(db)
                local success, err = db:execute([[
                    ALTER TABLE schedules
                    ADD COLUMN max_consecutive_failures INTEGER NOT NULL DEFAULT 7
                ]])

                if err then
                    error("Failed to add max_consecutive_failures column: " .. err)
                end

                return true
            end)

            down(function(db)
                local success, err = db:execute([[
                    ALTER TABLE schedules
                    DROP COLUMN IF EXISTS max_consecutive_failures
                ]])

                if err then
                    error("Failed to drop max_consecutive_failures column: " .. err)
                end

                return true
            end)
        end)

        database("sqlite", function()
            up(function(db)
                local success, err = db:execute([[
                    ALTER TABLE schedules ADD COLUMN max_consecutive_failures INTEGER NOT NULL DEFAULT 7
                ]])

                if err then
                    error("Failed to add max_consecutive_failures column: " .. err)
                end

                return true
            end)

            down(function(db)
                -- SQLite cannot drop a column without recreating the table.
                print("Warning: SQLite column max_consecutive_failures not dropped (SQLite limitation)")
                return true
            end)
        end)
    end)
end)
