return require("migration").define(function()
    migration("Widen uploads.size to BIGINT", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    ALTER TABLE uploads ALTER COLUMN size TYPE BIGINT;
                ]])
                if err then
                    error(err)
                end
            end)

            down(function(db)
                local _, err = db:execute([[
                    ALTER TABLE uploads ALTER COLUMN size TYPE INTEGER;
                ]])
                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            -- SQLite INTEGER is a dynamic 64-bit type already; nothing to do.
        end)
    end)
end)
