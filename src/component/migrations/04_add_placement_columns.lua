-- Placement / hierarchy columns on components:
--   parent_id  self-FK, ON DELETE SET NULL (deleted parent orphans children to root)
--   position   lexorank string for O(1) sibling reorder
--   path       ancestor path: postgres ltree (labels = uuid with hyphens stripped),
--              sqlite materialized TEXT path "/<id>/<id>/" queried via LIKE prefix
return require("migration").define(function()
    migration("Add placement/hierarchy columns to components", function()
        database("postgres", function()
            up(function(db)
                local success, err = db:execute("CREATE EXTENSION IF NOT EXISTS ltree")
                if err then
                    error("Failed to create ltree extension: " .. err)
                end

                success, err = db:execute("ALTER TABLE components ADD COLUMN parent_id UUID REFERENCES components(component_id) ON DELETE SET NULL")
                if err then
                    error("Failed to add parent_id column: " .. err)
                end

                success, err = db:execute("ALTER TABLE components ADD COLUMN position TEXT")
                if err then
                    error("Failed to add position column: " .. err)
                end

                success, err = db:execute("ALTER TABLE components ADD COLUMN path ltree")
                if err then
                    error("Failed to add path column: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_parent_position ON components(parent_id, position)")
                if err then
                    error("Failed to create parent_position index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_path ON components USING GIST (path)")
                if err then
                    error("Failed to create path GiST index: " .. err)
                end

                return true
            end)

            down(function(db)
                local success, err = db:execute("DROP INDEX IF EXISTS idx_components_path")
                if err then
                    error("Failed to drop path index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_components_parent_position")
                if err then
                    error("Failed to drop parent_position index: " .. err)
                end

                success, err = db:execute("ALTER TABLE components DROP COLUMN IF EXISTS path")
                if err then
                    error("Failed to drop path column: " .. err)
                end

                success, err = db:execute("ALTER TABLE components DROP COLUMN IF EXISTS position")
                if err then
                    error("Failed to drop position column: " .. err)
                end

                success, err = db:execute("ALTER TABLE components DROP COLUMN IF EXISTS parent_id")
                if err then
                    error("Failed to drop parent_id column: " .. err)
                end

                return true
            end)
        end)

        database("sqlite", function()
            up(function(db)
                local success, err = db:execute("ALTER TABLE components ADD COLUMN parent_id TEXT REFERENCES components(component_id) ON DELETE SET NULL")
                if err then
                    error("Failed to add parent_id column: " .. err)
                end

                success, err = db:execute("ALTER TABLE components ADD COLUMN position TEXT")
                if err then
                    error("Failed to add position column: " .. err)
                end

                success, err = db:execute("ALTER TABLE components ADD COLUMN path TEXT")
                if err then
                    error("Failed to add path column: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_parent_position ON components(parent_id, position)")
                if err then
                    error("Failed to create parent_position index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_path ON components(path)")
                if err then
                    error("Failed to create path index: " .. err)
                end

                return true
            end)

            down(function(db)
                local success, err = db:execute("DROP INDEX IF EXISTS idx_components_path")
                if err then
                    error("Failed to drop path index: " .. err)
                end

                success, err = db:execute("DROP INDEX IF EXISTS idx_components_parent_position")
                if err then
                    error("Failed to drop parent_position index: " .. err)
                end

                -- SQLite < 3.35 cannot DROP COLUMN; rebuild without placement columns.
                success, err = db:execute([[
                    CREATE TABLE components_new (
                        component_id TEXT PRIMARY KEY,
                        impl_id TEXT NOT NULL,
                        private_context TEXT DEFAULT '{}',
                        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    )
                ]])
                if err then
                    error("Failed to create rebuild table: " .. err)
                end

                success, err = db:execute("INSERT INTO components_new (component_id, impl_id, private_context, created_at, updated_at) SELECT component_id, impl_id, private_context, created_at, updated_at FROM components")
                if err then
                    error("Failed to copy rows during rebuild: " .. err)
                end

                success, err = db:execute("DROP TABLE components")
                if err then
                    error("Failed to drop old table during rebuild: " .. err)
                end

                success, err = db:execute("ALTER TABLE components_new RENAME TO components")
                if err then
                    error("Failed to rename rebuild table: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_impl_id ON components(impl_id)")
                if err then
                    error("Failed to recreate impl_id index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_created_at ON components(created_at)")
                if err then
                    error("Failed to recreate created_at index: " .. err)
                end

                success, err = db:execute("CREATE INDEX idx_components_updated_at ON components(updated_at)")
                if err then
                    error("Failed to recreate updated_at index: " .. err)
                end

                return true
            end)
        end)
    end)
end)
