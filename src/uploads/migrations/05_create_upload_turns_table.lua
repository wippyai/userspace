return require("migration").define(function()
    migration("Create upload_turns table and index uploads for fair dispatch", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE upload_turns (
                        user_id TEXT PRIMARY KEY,
                        served_at BIGINT NOT NULL
                    );
                ]])
                if err then
                    error(err)
                end

                _, err = db:execute("CREATE INDEX idx_uploads_pending_turn ON uploads(status, user_id, updated_at)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                local _, err = db:execute("DROP INDEX IF EXISTS idx_uploads_pending_turn")
                if err then
                    error(err)
                end

                _, err = db:execute("DROP TABLE IF EXISTS upload_turns")
                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE upload_turns (
                        user_id TEXT PRIMARY KEY,
                        served_at INTEGER NOT NULL
                    )
                ]])
                if err then
                    error(err)
                end

                _, err = db:execute("CREATE INDEX idx_uploads_pending_turn ON uploads(status, user_id, updated_at)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                local _, err = db:execute("DROP INDEX IF EXISTS idx_uploads_pending_turn")
                if err then
                    error(err)
                end

                _, err = db:execute("DROP TABLE IF EXISTS upload_turns")
                if err then
                    error(err)
                end
            end)
        end)
    end)
end)
