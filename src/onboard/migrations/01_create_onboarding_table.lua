return require("migration").define(function()
    migration("Create onboarding table", function()
        database("postgres", function()
            up(function(db)
                -- Create onboarding table
                local success, err = db:execute([[
                    CREATE TABLE IF NOT EXISTS onboarding (
                        user_id TEXT NOT NULL,
                        flag TEXT NOT NULL,
                        completed_at TIMESTAMP NOT NULL DEFAULT now(),
                        PRIMARY KEY (user_id, flag)
                    )
                ]])

                if err then
                    error(err)
                end
            end)

            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS onboarding")
                if err then
                    error(err)
                end
            end)
        end)


        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE IF NOT EXISTS onboarding (
                        user_id TEXT NOT NULL,
                        flag TEXT NOT NULL,
                        completed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        PRIMARY KEY (user_id, flag)
                    );
                ]])

                if err then
                    error(err)
                end
            end)

            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS onboarding;")
                if err then
                    error(err)
                end
            end)
        end)
    end)
end)
