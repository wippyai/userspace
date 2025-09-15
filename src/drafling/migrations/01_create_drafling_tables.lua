return require("migration").define(function()
    migration("Create drafling system tables", function()
        database("postgres", function()
            up(function(db)
                -- Create drafling_projects table
                local success, err = db:execute([[
                    CREATE TABLE drafling_projects (
                        project_id UUID PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        project_type TEXT NOT NULL,
                        title TEXT,
                        status TEXT,
                        metadata JSONB DEFAULT '{}',
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        updated_at TIMESTAMP NOT NULL DEFAULT now()
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes for drafling_projects
                success, err = db:execute("CREATE INDEX idx_drafling_projects_user_type ON drafling_projects(user_id, project_type)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_drafling_projects_user_status ON drafling_projects(user_id, status)")
                if err then
                    error(err)
                end

                -- Create drafling_categories table
                success, err = db:execute([[
                    CREATE TABLE drafling_categories (
                        category_id UUID PRIMARY KEY,
                        project_id UUID NOT NULL,
                        name TEXT NOT NULL,
                        display_name TEXT,
                        metadata JSONB DEFAULT '{}',
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        FOREIGN KEY (project_id) REFERENCES drafling_projects(project_id) ON DELETE CASCADE,
                        UNIQUE(project_id, name)
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes for drafling_categories
                success, err = db:execute("CREATE INDEX idx_drafling_categories_project ON drafling_categories(project_id)")
                if err then
                    error(err)
                end

                -- Create drafling_entries table
                success, err = db:execute([[
                    CREATE TABLE drafling_entries (
                        entry_id UUID PRIMARY KEY,
                        project_id UUID NOT NULL,
                        category_id UUID NOT NULL,
                        type TEXT NOT NULL,
                        content TEXT,
                        content_type TEXT DEFAULT 'text/plain',
                        title TEXT,
                        status TEXT,
                        metadata JSONB DEFAULT '{}',
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        updated_at TIMESTAMP NOT NULL DEFAULT now(),
                        FOREIGN KEY (project_id) REFERENCES drafling_projects(project_id) ON DELETE CASCADE,
                        FOREIGN KEY (category_id) REFERENCES drafling_categories(category_id) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes for drafling_entries
                success, err = db:execute("CREATE INDEX idx_drafling_entries_project ON drafling_entries(project_id, created_at DESC)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_drafling_entries_category ON drafling_entries(category_id, created_at DESC)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_drafling_entries_project_category ON drafling_entries(project_id, category_id, created_at DESC)")
                if err then
                    error(err)
                end

                -- Create drafling_entry_history table
                success, err = db:execute([[
                    CREATE TABLE drafling_entry_history (
                        history_id UUID PRIMARY KEY,
                        entry_id UUID NOT NULL,
                        project_id UUID NOT NULL,
                        operation_type TEXT NOT NULL,
                        changes JSONB,
                        created_at TIMESTAMP NOT NULL DEFAULT now(),
                        FOREIGN KEY (entry_id) REFERENCES drafling_entries(entry_id) ON DELETE CASCADE,
                        FOREIGN KEY (project_id) REFERENCES drafling_projects(project_id) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes for drafling_entry_history
                success, err = db:execute("CREATE INDEX idx_drafling_entry_history_entry ON drafling_entry_history(entry_id, created_at DESC)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_drafling_entry_history_project ON drafling_entry_history(project_id, created_at DESC)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                local success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entry_history_project")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entry_history_entry")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP TABLE IF EXISTS drafling_entry_history")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entries_project_category")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entries_category")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entries_project")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP TABLE IF EXISTS drafling_entries")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_categories_project")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP TABLE IF EXISTS drafling_categories")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_projects_user_status")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_projects_user_type")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP TABLE IF EXISTS drafling_projects")
                if err then
                    error(err)
                end
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- Create drafling_projects table
                local success, err = db:execute([[
                    CREATE TABLE drafling_projects (
                        project_id TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        project_type TEXT NOT NULL,
                        title TEXT,
                        status TEXT,
                        metadata TEXT DEFAULT '{}',
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes for drafling_projects
                success, err = db:execute("CREATE INDEX idx_drafling_projects_user_type ON drafling_projects(user_id, project_type)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_drafling_projects_user_status ON drafling_projects(user_id, status)")
                if err then
                    error(err)
                end

                -- Create drafling_categories table
                success, err = db:execute([[
                    CREATE TABLE drafling_categories (
                        category_id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        display_name TEXT,
                        metadata TEXT DEFAULT '{}',
                        created_at INTEGER NOT NULL,
                        FOREIGN KEY (project_id) REFERENCES drafling_projects(project_id) ON DELETE CASCADE,
                        UNIQUE(project_id, name)
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes for drafling_categories
                success, err = db:execute("CREATE INDEX idx_drafling_categories_project ON drafling_categories(project_id)")
                if err then
                    error(err)
                end

                -- Create drafling_entries table
                success, err = db:execute([[
                    CREATE TABLE drafling_entries (
                        entry_id TEXT PRIMARY KEY,
                        project_id TEXT NOT NULL,
                        category_id TEXT NOT NULL,
                        type TEXT NOT NULL,
                        content TEXT,
                        content_type TEXT DEFAULT 'text/plain',
                        title TEXT,
                        status TEXT,
                        metadata TEXT DEFAULT '{}',
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        FOREIGN KEY (project_id) REFERENCES drafling_projects(project_id) ON DELETE NO ACTION,
                        FOREIGN KEY (category_id) REFERENCES drafling_categories(category_id) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes for drafling_entries
                success, err = db:execute("CREATE INDEX idx_drafling_entries_project ON drafling_entries(project_id, created_at DESC)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_drafling_entries_category ON drafling_entries(category_id, created_at DESC)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_drafling_entries_project_category ON drafling_entries(project_id, category_id, created_at DESC)")
                if err then
                    error(err)
                end

                -- Create drafling_entry_history table
                success, err = db:execute([[
                    CREATE TABLE drafling_entry_history (
                        history_id TEXT PRIMARY KEY,
                        entry_id TEXT NOT NULL,
                        project_id TEXT NOT NULL,
                        operation_type TEXT NOT NULL,
                        changes TEXT,
                        created_at INTEGER NOT NULL,
                        FOREIGN KEY (entry_id) REFERENCES drafling_entries(entry_id) ON DELETE NO ACTION,
                        FOREIGN KEY (project_id) REFERENCES drafling_projects(project_id) ON DELETE CASCADE
                    )
                ]])

                if err then
                    error(err)
                end

                -- Create indexes for drafling_entry_history
                success, err = db:execute("CREATE INDEX idx_drafling_entry_history_entry ON drafling_entry_history(entry_id, created_at DESC)")
                if err then
                    error(err)
                end

                success, err = db:execute("CREATE INDEX idx_drafling_entry_history_project ON drafling_entry_history(project_id, created_at DESC)")
                if err then
                    error(err)
                end
            end)

            down(function(db)
                local success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entry_history_project")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entry_history_entry")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP TABLE IF EXISTS drafling_entry_history")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entries_project_category")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entries_category")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_entries_project")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP TABLE IF EXISTS drafling_entries")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_categories_project")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP TABLE IF EXISTS drafling_categories")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_projects_user_status")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_drafling_projects_user_type")
                if err then
                    error(err)
                end

                success, err = db:execute("DROP TABLE IF EXISTS drafling_projects")
                if err then
                    error(err)
                end
            end)
        end)
    end)
end)