local sql = require("sql")
local json = require("json")
local time = require("time")
local uuid = require("uuid")
local consts = require("drafling_consts")

local doc_repo = {}

-- ============================================================================
-- PRIVATE HELPERS
-- ============================================================================

-- Get database connection
local function get_db()
    local db, err = sql.get(consts.APP_DB)
    if err then
        return nil, "Failed to connect to database: " .. err
    end
    return db
end

-- Parse JSON fields in project data
local function parse_project(doc_row)
    if not doc_row then
        return nil
    end

    -- Parse metadata JSON
    if doc_row.metadata and type(doc_row.metadata) == "string" then
        local decoded, err = json.decode(doc_row.metadata)
        if not err then
            doc_row.metadata = decoded
        else
            doc_row.metadata = {}
        end
    elseif doc_row.metadata == nil then
        doc_row.metadata = {}
    end

    return doc_row
end

-- Parse JSON fields in category data
local function parse_category(cat_row)
    if not cat_row then
        return nil
    end

    -- Parse metadata JSON
    if cat_row.metadata and type(cat_row.metadata) == "string" then
        local decoded, err = json.decode(cat_row.metadata)
        if not err then
            cat_row.metadata = decoded
        else
            cat_row.metadata = {}
        end
    elseif cat_row.metadata == nil then
        cat_row.metadata = {}
    end

    return cat_row
end

-- ============================================================================
-- PROJECT OPERATIONS
-- ============================================================================

-- Create a new project
function doc_repo.create(user_id, project_type, title, metadata)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    if not project_type or project_type == "" then
        return nil, "Document type is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local project_id = uuid.v7()
    local now_ts = time.now():format(time.RFC3339NANO)

    -- Process metadata
    local metadata_json = "{}"
    if metadata ~= nil then
        if type(metadata) == "table" then
            local encoded, err = json.encode(metadata)
            if err then
                db:release()
                return nil, "Failed to encode metadata: " .. err
            end
            metadata_json = encoded
        elseif type(metadata) == "string" then
            metadata_json = metadata
        end
    end

    local insert_query = sql.builder.insert("drafling_projects")
        :set_map({
            project_id = project_id,
            user_id = user_id,
            project_type = project_type,
            title = title,
            status = consts.STATUS.DRAFT,
            metadata = metadata_json,
            created_at = now_ts,
            updated_at = now_ts
        })

    local executor = insert_query:run_with(db)
    local result, err = executor:exec()
    db:release()

    if err then
        return nil, "Failed to create project: " .. err
    end

    return {
        project_id = project_id,
        user_id = user_id,
        project_type = project_type,
        title = title,
        status = consts.STATUS.DRAFT,
        metadata = type(metadata) == "table" and metadata or {},
        created_at = now_ts,
        updated_at = now_ts
    }
end

-- Get a project by ID
function doc_repo.get(project_id, user_id)
    if not project_id or project_id == "" then
        return nil, "Document ID is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local query = sql.builder.select("*")
        :from("drafling_projects")
        :where("project_id = ?", project_id)

    -- Add user filter for security
    if user_id then
        query = query:where("user_id = ?", user_id)
    end

    query = query:limit(1)

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to get project: " .. err
    end

    if not results or #results == 0 then
        return nil, "Document not found"
    end

    return parse_project(results[1])
end

-- Update a project
function doc_repo.update(project_id, user_id, updates)
    if not project_id or project_id == "" then
        return nil, "Document ID is required"
    end

    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    if not updates or type(updates) ~= "table" then
        return nil, "Updates must be a table"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local update_query = sql.builder.update("drafling_projects")
        :where("project_id = ?", project_id)
        :where("user_id = ?", user_id)

    local has_update = false

    if updates.title then
        update_query = update_query:set("title", updates.title)
        has_update = true
    end

    if updates.status then
        update_query = update_query:set("status", updates.status)
        has_update = true
    end

    if updates.metadata then
        local metadata = updates.metadata
        if type(metadata) == "table" then
            local encoded, err = json.encode(metadata)
            if err then
                db:release()
                return nil, "Failed to encode metadata: " .. err
            end
            metadata = encoded
        end
        update_query = update_query:set("metadata", metadata)
        has_update = true
    end

    if not has_update then
        db:release()
        return nil, "No valid fields to update"
    end

    local now_ts = time.now():format(time.RFC3339NANO)
    update_query = update_query:set("updated_at", now_ts)

    local executor = update_query:run_with(db)
    local result, err = executor:exec()
    db:release()

    if err then
        return nil, "Failed to update project: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Document not found or no access"
    end

    return { rows_affected = result.rows_affected }
end

-- Delete a project
function doc_repo.delete(project_id, user_id)
    if not project_id or project_id == "" then
        return nil, "Document ID is required"
    end

    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local delete_query = sql.builder.delete("drafling_projects")
        :where("project_id = ?", project_id)
        :where("user_id = ?", user_id)

    local executor = delete_query:run_with(db)
    local result, err = executor:exec()
    db:release()

    if err then
        return nil, "Failed to delete project: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Document not found or no access"
    end

    return { rows_affected = result.rows_affected }
end

-- List projects for a user
function doc_repo.list_by_user(user_id, options)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    options = options or {}

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local query = sql.builder.select("*")
        :from("drafling_projects")
        :where("user_id = ?", user_id)

    -- Filter by project type
    if options.project_type then
        query = query:where("project_type = ?", options.project_type)
    end

    -- Filter by status
    if options.status then
        query = query:where("status = ?", options.status)
    end

    -- Ordering
    if options.order_by == "updated" then
        query = query:order_by("updated_at DESC")
    elseif options.order_by == "title" then
        query = query:order_by("title ASC")
    else
        query = query:order_by("created_at DESC")
    end

    -- Pagination
    if options.limit and tonumber(options.limit) > 0 then
        query = query:limit(tonumber(options.limit))
    end

    if options.offset and tonumber(options.offset) >= 0 then
        query = query:offset(tonumber(options.offset))
    end

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to list projects: " .. err
    end

    -- Parse metadata in all results
    local projects = {}
    for _, row in ipairs(results or {}) do
        table.insert(projects, parse_project(row))
    end

    return projects
end

-- ============================================================================
-- CATEGORY OPERATIONS
-- ============================================================================

-- Create categories for a project
function doc_repo.create_categories(project_id, categories)
    if not project_id or project_id == "" then
        return nil, "Document ID is required"
    end

    if not categories or type(categories) ~= "table" or #categories == 0 then
        return nil, "Categories array is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local tx, err_tx = db:begin()
    if err_tx then
        db:release()
        return nil, "Failed to begin transaction: " .. err_tx
    end

    local created_categories = {}
    local now_ts = time.now():format(time.RFC3339NANO)

    for _, cat in ipairs(categories) do
        if not cat.name then
            tx:rollback()
            db:release()
            return nil, "Category name is required"
        end

        local category_id = uuid.v7()

        local metadata_json = "{}"
        if cat.metadata and type(cat.metadata) == "table" then
            local encoded, err = json.encode(cat.metadata)
            if err then
                tx:rollback()
                db:release()
                return nil, "Failed to encode category metadata: " .. err
            end
            metadata_json = encoded
        end

        local insert_query = sql.builder.insert("drafling_categories")
            :set_map({
                category_id = category_id,
                project_id = project_id,
                name = cat.name,
                display_name = cat.display_name,
                metadata = metadata_json,
                created_at = now_ts
            })

        local executor = insert_query:run_with(tx)
        local result, err = executor:exec()

        if err then
            tx:rollback()
            db:release()
            return nil, "Failed to create category: " .. err
        end

        table.insert(created_categories, {
            category_id = category_id,
            project_id = project_id,
            name = cat.name,
            display_name = cat.display_name,
            metadata = cat.metadata or {},
            created_at = now_ts
        })
    end

    local _, err_commit = tx:commit()
    if err_commit then
        tx:rollback()
        db:release()
        return nil, "Failed to commit transaction: " .. err_commit
    end

    db:release()
    return created_categories
end

-- Get categories for a project
function doc_repo.get_categories(project_id)
    if not project_id or project_id == "" then
        return nil, "Document ID is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local query = sql.builder.select("*")
        :from("drafling_categories")
        :where("project_id = ?", project_id)
        :order_by("created_at ASC")

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to get categories: " .. err
    end

    -- Parse metadata in all results
    local categories = {}
    for _, row in ipairs(results or {}) do
        table.insert(categories, parse_category(row))
    end

    return categories
end

-- ============================================================================
-- ANALYTICS AND DISCOVERY
-- ============================================================================

-- Get all unique category names across user's projects
function doc_repo.get_unique_categories(user_id)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local query = sql.builder.select("DISTINCT c.name")
        :from("drafling_categories c")
        :join("drafling_projects d ON c.project_id = d.project_id")
        :where("d.user_id = ?", user_id)
        :order_by("c.name ASC")

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to get unique categories: " .. err
    end

    local categories = {}
    for _, row in ipairs(results or {}) do
        table.insert(categories, row.name)
    end

    return categories
end

-- Get all unique entry types across user's projects
function doc_repo.get_unique_entry_types(user_id)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    local query = sql.builder.select("DISTINCT e.type")
        :from("drafling_entries e")
        :join("drafling_projects d ON e.project_id = d.project_id")
        :where("d.user_id = ?", user_id)
        :order_by("e.type ASC")

    local executor = query:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to get unique entry types: " .. err
    end

    local types = {}
    for _, row in ipairs(results or {}) do
        table.insert(types, row.type)
    end

    return types
end

-- Get project statistics for a user
function doc_repo.get_user_stats(user_id)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    -- Get project counts by type and status
    local doc_stats_query = sql.builder.select("project_type", "status", "COUNT(*) as count")
        :from("drafling_projects")
        :where("user_id = ?", user_id)
        :group_by("project_type, status")
        :order_by("project_type, status")

    local doc_executor = doc_stats_query:run_with(db)
    local doc_results, doc_err = doc_executor:query()

    if doc_err then
        db:release()
        return nil, "Failed to get project stats: " .. doc_err
    end

    -- Get entry counts by type
    local entry_stats_query = sql.builder.select("e.type", "COUNT(*) as count")
        :from("drafling_entries e")
        :join("drafling_projects d ON e.project_id = d.project_id")
        :where("d.user_id = ?", user_id)
        :group_by("e.type")
        :order_by("e.type")

    local entry_executor = entry_stats_query:run_with(db)
    local entry_results, entry_err = entry_executor:query()

    db:release()

    if entry_err then
        return nil, "Failed to get entry stats: " .. entry_err
    end

    return {
        projects_by_type_status = doc_results or {},
        entries_by_type = entry_results or {}
    }
end

return doc_repo