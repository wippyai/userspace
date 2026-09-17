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
            -- SQLite INTEGER is already a 64-bit type, so there is no schema change;
            -- the runner still requires both directions to be declared.
            up(function(_db) end)
            down(function(_db) end)
        end)
    end)
end)
