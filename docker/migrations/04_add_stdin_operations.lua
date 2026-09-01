return require("migration").define(function()
    migration("Add durable container transport cursors and stdin operations", function()
        database("postgres", function()
            up(function(db)
                db:execute("ALTER TABLE container_logs ADD COLUMN sequence BIGINT")
                db:execute([[
                    WITH ranked AS (
                        SELECT id, ROW_NUMBER() OVER (PARTITION BY container_id ORDER BY id) AS seq
                        FROM container_logs
                    )
                    UPDATE container_logs SET sequence = ranked.seq
                    FROM ranked WHERE container_logs.id = ranked.id
                ]])
                db:execute("ALTER TABLE container_logs ALTER COLUMN sequence SET NOT NULL")
                db:execute("CREATE UNIQUE INDEX idx_container_logs_sequence ON container_logs(container_id, sequence)")
                db:execute([[
                    CREATE TABLE container_stdin_operations (
                        operation_id TEXT PRIMARY KEY,
                        container_id TEXT NOT NULL REFERENCES containers(id) ON DELETE CASCADE,
                        request_digest TEXT NOT NULL,
                        byte_count INTEGER NOT NULL,
                        state TEXT NOT NULL,
                        backend TEXT,
                        error TEXT,
                        created_at BIGINT NOT NULL,
                        updated_at BIGINT NOT NULL
                    )
                ]])
                db:execute("CREATE INDEX idx_container_stdin_operations_container ON container_stdin_operations(container_id, created_at)")
            end)
            down(function(db)
                db:execute("DROP INDEX IF EXISTS idx_container_stdin_operations_container")
                db:execute("DROP TABLE IF EXISTS container_stdin_operations")
                db:execute("DROP INDEX IF EXISTS idx_container_logs_sequence")
                db:execute("ALTER TABLE container_logs DROP COLUMN sequence")
            end)
        end)
        database("sqlite", function()
            up(function(db)
                db:execute("ALTER TABLE container_logs ADD COLUMN sequence INTEGER")
                db:execute([[
                    UPDATE container_logs AS current SET sequence = (
                        SELECT COUNT(*) FROM container_logs AS prior
                        WHERE prior.container_id = current.container_id AND prior.id <= current.id
                    )
                ]])
                db:execute("CREATE UNIQUE INDEX idx_container_logs_sequence ON container_logs(container_id, sequence)")
                db:execute([[
                    CREATE TABLE container_stdin_operations (
                        operation_id TEXT PRIMARY KEY,
                        container_id TEXT NOT NULL,
                        request_digest TEXT NOT NULL,
                        byte_count INTEGER NOT NULL,
                        state TEXT NOT NULL,
                        backend TEXT,
                        error TEXT,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        FOREIGN KEY (container_id) REFERENCES containers(id) ON DELETE CASCADE
                    )
                ]])
                db:execute("CREATE INDEX idx_container_stdin_operations_container ON container_stdin_operations(container_id, created_at)")
            end)
            down(function(db)
                db:execute("DROP INDEX IF EXISTS idx_container_stdin_operations_container")
                db:execute("DROP TABLE IF EXISTS container_stdin_operations")
                db:execute("DROP INDEX IF EXISTS idx_container_logs_sequence")
                db:execute("ALTER TABLE container_logs DROP COLUMN sequence")
            end)
        end)
    end)
end)
