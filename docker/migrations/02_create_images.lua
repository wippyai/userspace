return require("migration").define(function()
    migration("Create images and image_builds tables", function()
        database("postgres", function()
            up(function(db)
                db:execute([[
                    CREATE TABLE images (
                        id TEXT PRIMARY KEY,
                        docker_id TEXT,
                        name TEXT NOT NULL,
                        tag TEXT NOT NULL DEFAULT 'latest',
                        source TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'available',
                        size BIGINT,
                        error TEXT,
                        created_at BIGINT NOT NULL,
                        updated_at BIGINT
                    )
                ]])
                db:execute([[
                    CREATE INDEX idx_images_name_tag ON images(name, tag)
                ]])
                db:execute([[
                    CREATE TABLE image_builds (
                        id TEXT PRIMARY KEY,
                        image_id TEXT NOT NULL,
                        dockerfile TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'pending',
                        build_log TEXT,
                        error TEXT,
                        created_at BIGINT NOT NULL,
                        started_at BIGINT,
                        completed_at BIGINT
                    )
                ]])
            end)
            down(function(db)
                db:execute("DROP TABLE IF EXISTS image_builds")
                db:execute("DROP INDEX IF EXISTS idx_images_name_tag")
                db:execute("DROP TABLE IF EXISTS images")
            end)
        end)
        database("sqlite", function()
            up(function(db)
                db:execute([[
                    CREATE TABLE images (
                        id TEXT PRIMARY KEY,
                        docker_id TEXT,
                        name TEXT NOT NULL,
                        tag TEXT NOT NULL DEFAULT 'latest',
                        source TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'available',
                        size INTEGER,
                        error TEXT,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER
                    )
                ]])
                db:execute([[
                    CREATE INDEX idx_images_name_tag ON images(name, tag)
                ]])
                db:execute([[
                    CREATE TABLE image_builds (
                        id TEXT PRIMARY KEY,
                        image_id TEXT NOT NULL,
                        dockerfile TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'pending',
                        build_log TEXT,
                        error TEXT,
                        created_at INTEGER NOT NULL,
                        started_at INTEGER,
                        completed_at INTEGER
                    )
                ]])
            end)
            down(function(db)
                db:execute("DROP TABLE IF EXISTS image_builds")
                db:execute("DROP INDEX IF EXISTS idx_images_name_tag")
                db:execute("DROP TABLE IF EXISTS images")
            end)
        end)
    end)
end)
