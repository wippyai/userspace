return require("migration").define(function()
    migration("Create schedules table for task scheduling", function()
        -- PostgreSQL implementation
        database("postgres", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE schedules (
                        id UUID PRIMARY KEY,
                        description TEXT,

                        -- Classification and ownership
                        class TEXT NOT NULL DEFAULT 'user',
                        user_id TEXT,

                        -- What to execute (implementation-based)
                        task_implementation_id TEXT NOT NULL,
                        task_context JSONB DEFAULT '{}',
                        task_args JSONB DEFAULT '{}',

                        -- When to execute
                        schedule_type TEXT NOT NULL,
                        schedule_expression TEXT NOT NULL,
                        next_run_at TIMESTAMP,
                        last_run_at TIMESTAMP,

                        -- Execution state
                        status TEXT NOT NULL DEFAULT 'scheduled',
                        enabled BOOLEAN NOT NULL DEFAULT TRUE,
                        picked BOOLEAN NOT NULL DEFAULT FALSE,
                        picked_by TEXT,
                        picked_at TIMESTAMP,

                        -- Task execution timeout (seconds from picked_at)
                        timeout_seconds INTEGER NOT NULL DEFAULT 3600,

                        -- Retry and error handling
                        retry_count INTEGER NOT NULL DEFAULT 0,
                        max_retries INTEGER NOT NULL DEFAULT 3,
                        consecutive_failures INTEGER NOT NULL DEFAULT 0,
                        last_error TEXT,

                        -- Standard audit
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        updated_at TIMESTAMP NOT NULL DEFAULT now()
                    )
                ]])

                if err then
                    error("Failed to create schedules table: " .. err)
                end

                -- Essential indexes for performance
                success, err = db:execute("CREATE INDEX idx_schedules_next_run ON schedules(next_run_at) WHERE enabled = TRUE AND picked = FALSE AND status = 'scheduled'")
                if err then
                    error("Failed to create next_run index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_schedules_class_user ON schedules(class, user_id)")
                if err then
                    error("Failed to create class_user index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_schedules_task_implementation ON schedules(task_implementation_id)")
                if err then
                    error("Failed to create task_implementation index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_schedules_picked_by ON schedules(picked_by) WHERE picked = TRUE")
                if err then
                    error("Failed to create picked_by index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_schedules_status ON schedules(status)")
                if err then
                    error("Failed to create status index: " .. err)
                end

                -- Background cleanup index for stuck tasks
                success, err = db:execute("CREATE INDEX idx_schedules_stuck_tasks ON schedules(picked_at, timeout_seconds) WHERE picked = TRUE AND status = 'executing'")
                if err then
                    error("Failed to create stuck_tasks index: " .. err)
                end

                return true
            end)

            down(function(db)
                local success, err = db:execute("DROP TABLE IF EXISTS schedules CASCADE")
                if err then
                    error("Failed to drop schedules table: " .. err)
                end

                return true
            end)
        end)

        -- SQLite implementation
        database("sqlite", function()
            up(function(db)
                local success, err = db:execute([[
                    CREATE TABLE schedules (
                        id TEXT PRIMARY KEY,
                        description TEXT,

                        -- Classification and ownership
                        class TEXT NOT NULL DEFAULT 'user',
                        user_id TEXT,

                        -- What to execute (implementation-based)
                        task_implementation_id TEXT NOT NULL,
                        task_context TEXT DEFAULT '{}',
                        task_args TEXT DEFAULT '{}',

                        -- When to execute
                        schedule_type TEXT NOT NULL,
                        schedule_expression TEXT NOT NULL,
                        next_run_at INTEGER,
                        last_run_at INTEGER,

                        -- Execution state
                        status TEXT NOT NULL DEFAULT 'scheduled',
                        enabled BOOLEAN NOT NULL DEFAULT TRUE,
                        picked BOOLEAN NOT NULL DEFAULT FALSE,
                        picked_by TEXT,
                        picked_at INTEGER,

                        -- Task execution timeout (seconds from picked_at)
                        timeout_seconds INTEGER NOT NULL DEFAULT 3600,

                        -- Retry and error handling
                        retry_count INTEGER NOT NULL DEFAULT 0,
                        max_retries INTEGER NOT NULL DEFAULT 3,
                        consecutive_failures INTEGER NOT NULL DEFAULT 0,
                        last_error TEXT,

                        -- Standard audit
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    )
                ]])

                if err then
                    error("Failed to create schedules table: " .. err)
                end

                -- Essential indexes for performance
                success, err = db:execute("CREATE INDEX idx_schedules_next_run ON schedules(next_run_at)")
                if err then
                    error("Failed to create next_run index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_schedules_class_user ON schedules(class, user_id)")
                if err then
                    error("Failed to create class_user index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_schedules_task_implementation ON schedules(task_implementation_id)")
                if err then
                    error("Failed to create task_implementation index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_schedules_picked_by ON schedules(picked_by)")
                if err then
                    error("Failed to create picked_by index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_schedules_status ON schedules(status)")
                if err then
                    error("Failed to create status index: " .. err)
                end

                -- Background cleanup index for stuck tasks
                success, err = db:execute("CREATE INDEX idx_schedules_stuck_tasks ON schedules(picked_at, timeout_seconds)")
                if err then
                    error("Failed to create stuck_tasks index: " .. err)
                end

                return true
            end)

            down(function(db)
                local success, err = db:execute("DROP TABLE IF EXISTS schedules")
                if err then
                    error("Failed to drop schedules table: " .. err)
                end

                return true
            end)
        end)
    end)
end)