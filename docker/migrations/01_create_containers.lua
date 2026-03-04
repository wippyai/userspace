return require("migration").define(function()
    migration("Create containers and container_logs tables", function()
        database("postgres", function()
            up(function(db)
                db:execute([[
                    CREATE TABLE containers (
                        id TEXT PRIMARY KEY,
                        docker_id TEXT,
                        name TEXT,
                        image TEXT NOT NULL,
                        command TEXT,
                        config JSONB NOT NULL DEFAULT '{}',
                        status TEXT NOT NULL DEFAULT 'pending',
                        exit_code INTEGER,
                        error TEXT,
                        labels JSONB,
                        callback_pid TEXT,
                        callback_topic TEXT,
                        persist_logs BOOLEAN DEFAULT true,
                        created_by TEXT,
                        created_at BIGINT NOT NULL,
                        started_at BIGINT,
                        stopped_at BIGINT
                    )
                ]])
                db:execute([[
                    CREATE INDEX idx_containers_status ON containers(status)
                ]])
                db:execute([[
                    CREATE TABLE container_logs (
                        id BIGSERIAL PRIMARY KEY,
                        container_id TEXT NOT NULL REFERENCES containers(id) ON DELETE CASCADE,
                        stream TEXT NOT NULL DEFAULT 'stdout',
                        line TEXT NOT NULL,
                        ts BIGINT NOT NULL
                    )
                ]])
                db:execute([[
                    CREATE INDEX idx_container_logs_container ON container_logs(container_id, id)
                ]])
            end)
            down(function(db)
                db:execute("DROP INDEX IF EXISTS idx_container_logs_container")
                db:execute("DROP TABLE IF EXISTS container_logs")
                db:execute("DROP INDEX IF EXISTS idx_containers_status")
                db:execute("DROP TABLE IF EXISTS containers")
            end)
        end)
        database("sqlite", function()
            up(function(db)
                db:execute([[
                    CREATE TABLE containers (
                        id TEXT PRIMARY KEY,
                        docker_id TEXT,
                        name TEXT,
                        image TEXT NOT NULL,
                        command TEXT,
                        config TEXT NOT NULL DEFAULT '{}',
                        status TEXT NOT NULL DEFAULT 'pending',
                        exit_code INTEGER,
                        error TEXT,
                        labels TEXT,
                        callback_pid TEXT,
                        callback_topic TEXT,
                        persist_logs INTEGER DEFAULT 1,
                        created_by TEXT,
                        created_at INTEGER NOT NULL,
                        started_at INTEGER,
                        stopped_at INTEGER
                    )
                ]])
                db:execute([[
                    CREATE INDEX idx_containers_status ON containers(status)
                ]])
                db:execute([[
                    CREATE TABLE container_logs (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        container_id TEXT NOT NULL,
                        stream TEXT NOT NULL DEFAULT 'stdout',
                        line TEXT NOT NULL,
                        ts INTEGER NOT NULL,
                        FOREIGN KEY (container_id) REFERENCES containers(id) ON DELETE CASCADE
                    )
                ]])
                db:execute([[
                    CREATE INDEX idx_container_logs_container ON container_logs(container_id, id)
                ]])
            end)
            down(function(db)
                db:execute("DROP INDEX IF EXISTS idx_container_logs_container")
                db:execute("DROP TABLE IF EXISTS container_logs")
                db:execute("DROP INDEX IF EXISTS idx_containers_status")
                db:execute("DROP TABLE IF EXISTS containers")
            end)
        end)
    end)
end)
