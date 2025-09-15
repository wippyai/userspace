local sql = require("sql")
local json = require("json")
local consts = require("drafling_consts")

local doc_reader = {}
local methods = {}
local reader_mt = { __index = methods }

-- ============================================================================
-- PRIVATE HELPERS
-- ============================================================================

-- Helper to create an immutable copy of a reader
function methods:_copy()
    local new_instance = {}
    for k, v in pairs(self) do
        new_instance[k] = v
    end
    return setmetatable(new_instance, reader_mt)
end

-- Helper to create a simple IN clause for arrays
local function create_in_clause(field, values)
    if not values or #values == 0 then
        return nil
    end

    if #values == 1 then
        return { field .. " = ?", values[1] }
    end

    local placeholders = {}
    for i = 1, #values do
        table.insert(placeholders, "?")
    end

    return { field .. " IN (" .. table.concat(placeholders, ", ") .. ")", unpack(values) }
end

-- Helper to get database connection
local function get_db()
    local db, err = sql.get(consts.APP_DB)
    if err then
        return nil, "Failed to connect to database: " .. err
    end
    return db, nil
end

-- Helper to create a parameterized IN clause
local function create_in_clause(field, values)
    if not values or #values == 0 then
        return nil
    end

    if #values == 1 then
        return { field .. " = ?", values[1] }
    end

    local placeholders = {}
    for i = 1, #values do
        table.insert(placeholders, "?")
    end

    return { field .. " IN (" .. table.concat(placeholders, ", ") .. ")", unpack(values) }
end

-- Parse JSON metadata string into table
local function parse_json_metadata(metadata_str)
    if not metadata_str or type(metadata_str) ~= "string" then
        return {}
    end

    local parsed, err = json.decode(metadata_str)
    if err then
        return {}
    else
        return parsed
    end
end

-- Parse metadata in result rows
local function parse_metadata(rows)
    for i, row in ipairs(rows) do
        if row.metadata then
            row.metadata = parse_json_metadata(row.metadata)
        else
            row.metadata = {}
        end

        if row.category_metadata then
            row.category_metadata = parse_json_metadata(row.category_metadata)
        end

        if row.entry_metadata then
            row.entry_metadata = parse_json_metadata(row.entry_metadata)
        end
    end
    return rows
end

-- ============================================================================
-- FLUENT API INITIALIZATION
-- ============================================================================

-- Initialize a new reader for a user
function doc_reader.with_user(user_id)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    local instance = {
        _user_id = user_id,
        _project_ids = nil,
        _project_types = nil,
        _project_statuses = nil,
        _category_names = nil,
        _entry_types = nil,
        _entry_statuses = nil,
        _include_categories = false,
        _include_entries = false,
        _fetch_content = true,
        _fetch_metadata = true,
    }
    return setmetatable(instance, reader_mt), nil
end

-- ============================================================================
-- FILTERING METHODS
-- ============================================================================

-- Filter by specific projects
function methods:with_projects(...)
    local new_instance = self:_copy()
    new_instance._project_ids = { ... }
    return new_instance
end

-- Filter by project types
function methods:with_project_types(...)
    local new_instance = self:_copy()
    new_instance._project_types = { ... }
    return new_instance
end

-- Filter by project statuses
function methods:with_project_statuses(...)
    local new_instance = self:_copy()
    new_instance._project_statuses = { ... }
    return new_instance
end

-- Filter by category names
function methods:with_categories(...)
    local new_instance = self:_copy()
    new_instance._category_names = { ... }
    return new_instance
end

-- Filter by entry types
function methods:with_entry_types(...)
    local new_instance = self:_copy()
    new_instance._entry_types = { ... }
    return new_instance
end

-- Filter by entry statuses
function methods:with_entry_statuses(...)
    local new_instance = self:_copy()
    new_instance._entry_statuses = { ... }
    return new_instance
end

-- ============================================================================
-- INCLUDE METHODS
-- ============================================================================

-- Include categories in results
function methods:include_categories()
    local new_instance = self:_copy()
    new_instance._include_categories = true
    return new_instance
end

-- Include entries in results
function methods:include_entries()
    local new_instance = self:_copy()
    new_instance._include_entries = true
    return new_instance
end

-- Configure fetch options
function methods:fetch_options(options)
    if not options or type(options) ~= "table" then
        return self
    end

    local new_instance = self:_copy()

    if options.content ~= nil then
        new_instance._fetch_content = options.content
    end

    if options.metadata ~= nil then
        new_instance._fetch_metadata = options.metadata
    end

    return new_instance
end

-- ============================================================================
-- QUERY BUILDING
-- ============================================================================

function methods:_build_projects_query()
    local select_fields = { "d.project_id", "d.user_id", "d.project_type", "d.title",
                           "d.status", "d.created_at", "d.updated_at" }

    if self._fetch_metadata then
        table.insert(select_fields, "d.metadata")
    end

    local query_builder = sql.builder.select(unpack(select_fields))
        :from("drafling_projects d")
        :where("d.user_id = ?", self._user_id)

    -- Apply project filters
    if self._project_ids and #self._project_ids > 0 then
        local doc_clause = create_in_clause("d.project_id", self._project_ids)
        if doc_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(doc_clause)))
        end
    end

    if self._project_types and #self._project_types > 0 then
        local type_clause = create_in_clause("d.project_type", self._project_types)
        if type_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(type_clause)))
        end
    end

    if self._project_statuses and #self._project_statuses > 0 then
        local status_clause = create_in_clause("d.status", self._project_statuses)
        if status_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(status_clause)))
        end
    end

    -- Apply category-based project filtering
    if self._category_names and #self._category_names > 0 then
        query_builder = query_builder
            :join("drafling_categories cat_filter ON cat_filter.project_id = d.project_id")

        local cat_clause = create_in_clause("cat_filter.name", self._category_names)
        if cat_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(cat_clause)))
        end
    end

    -- Apply entry-based project filtering
    if (self._entry_types and #self._entry_types > 0) or (self._entry_statuses and #self._entry_statuses > 0) then
        query_builder = query_builder
            :join("drafling_entries entry_filter ON entry_filter.project_id = d.project_id")

        if self._entry_types and #self._entry_types > 0 then
            local type_clause = create_in_clause("entry_filter.type", self._entry_types)
            if type_clause then
                query_builder = query_builder:where(sql.builder.expr(unpack(type_clause)))
            end
        end

        if self._entry_statuses and #self._entry_statuses > 0 then
            local status_clause = create_in_clause("entry_filter.status", self._entry_statuses)
            if status_clause then
                query_builder = query_builder:where(sql.builder.expr(unpack(status_clause)))
            end
        end
    end

    -- Add DISTINCT to avoid duplicates from joins
    if (self._category_names and #self._category_names > 0) or
       (self._entry_types and #self._entry_types > 0) or
       (self._entry_statuses and #self._entry_statuses > 0) then
        query_builder = query_builder:distinct()
    end

    query_builder = query_builder:order_by("d.created_at DESC")

    return query_builder
end

function methods:_build_categories_query(project_ids)
    if not project_ids or #project_ids == 0 then
        return nil
    end

    local select_fields = { "c.category_id", "c.project_id", "c.name", "c.display_name", "c.created_at" }

    if self._fetch_metadata then
        table.insert(select_fields, "c.metadata as category_metadata")
    end

    local query_builder = sql.builder.select(unpack(select_fields))
        :from("drafling_categories c")

    local doc_clause = create_in_clause("c.project_id", project_ids)
    if doc_clause then
        query_builder = query_builder:where(sql.builder.expr(unpack(doc_clause)))
    end

    query_builder = query_builder:order_by("c.project_id, c.created_at ASC")

    return query_builder
end

function methods:_build_entries_query(project_ids)
    if not project_ids or #project_ids == 0 then
        return nil
    end

    local select_fields = { "e.entry_id", "e.project_id", "e.category_id", "e.type",
                           "e.content_type", "e.title", "e.status", "e.created_at", "e.updated_at" }

    if self._fetch_content then
        table.insert(select_fields, "e.content")
    end

    if self._fetch_metadata then
        table.insert(select_fields, "e.metadata as entry_metadata")
    end

    local query_builder = sql.builder.select(unpack(select_fields))
        :from("drafling_entries e")

    local doc_clause = create_in_clause("e.project_id", project_ids)
    if doc_clause then
        query_builder = query_builder:where(sql.builder.expr(unpack(doc_clause)))
    end

    query_builder = query_builder:order_by("e.project_id, e.category_id, e.created_at ASC")

    return query_builder
end

function methods:_build_single_query_with_joins()
    local select_fields = { "d.project_id", "d.user_id", "d.project_type", "d.title",
                           "d.status", "d.created_at", "d.updated_at" }

    if self._fetch_metadata then
        table.insert(select_fields, "d.metadata")
    end

    -- Add category fields if including categories
    if self._include_categories then
        table.insert(select_fields, "c.category_id")
        table.insert(select_fields, "c.name as category_name")
        table.insert(select_fields, "c.display_name as category_display_name")
        table.insert(select_fields, "c.created_at as category_created_at")

        if self._fetch_metadata then
            table.insert(select_fields, "c.metadata as category_metadata")
        end
    end

    -- Add entry fields if including entries
    if self._include_entries then
        table.insert(select_fields, "e.entry_id")
        table.insert(select_fields, "e.category_id as entry_category_id")
        table.insert(select_fields, "e.type as entry_type")
        table.insert(select_fields, "e.content_type as entry_content_type")
        table.insert(select_fields, "e.title as entry_title")
        table.insert(select_fields, "e.status as entry_status")
        table.insert(select_fields, "e.created_at as entry_created_at")
        table.insert(select_fields, "e.updated_at as entry_updated_at")

        if self._fetch_content then
            table.insert(select_fields, "e.content as entry_content")
        end

        if self._fetch_metadata then
            table.insert(select_fields, "e.metadata as entry_metadata")
        end
    end

    local query_builder = sql.builder.select(unpack(select_fields))
        :from("drafling_projects d")
        :where("d.user_id = ?", self._user_id)

    -- Add JOINs for includes
    if self._include_categories then
        query_builder = query_builder:left_join("drafling_categories c ON c.project_id = d.project_id")
    end

    if self._include_entries then
        query_builder = query_builder:left_join("drafling_entries e ON e.project_id = d.project_id")
    end

    -- Apply project filters
    if self._project_ids and #self._project_ids > 0 then
        local doc_clause = create_in_clause("d.project_id", self._project_ids)
        if doc_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(doc_clause)))
        end
    end

    if self._project_types and #self._project_types > 0 then
        local type_clause = create_in_clause("d.project_type", self._project_types)
        if type_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(type_clause)))
        end
    end

    if self._project_statuses and #self._project_statuses > 0 then
        local status_clause = create_in_clause("d.status", self._project_statuses)
        if status_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(status_clause)))
        end
    end

    -- Apply category-based project filtering
    if self._category_names and #self._category_names > 0 then
        if not self._include_categories then
            query_builder = query_builder
                :join("drafling_categories cat_filter ON cat_filter.project_id = d.project_id")

            local cat_clause = create_in_clause("cat_filter.name", self._category_names)
            if cat_clause then
                query_builder = query_builder:where(sql.builder.expr(unpack(cat_clause)))
            end
        else
            local cat_clause = create_in_clause("c.name", self._category_names)
            if cat_clause then
                query_builder = query_builder:where(sql.builder.expr(unpack(cat_clause)))
            end
        end
    end

    -- Apply entry-based project filtering
    if (self._entry_types and #self._entry_types > 0) or (self._entry_statuses and #self._entry_statuses > 0) then
        if not self._include_entries then
            query_builder = query_builder
                :join("drafling_entries entry_filter ON entry_filter.project_id = d.project_id")

            if self._entry_types and #self._entry_types > 0 then
                local type_clause = create_in_clause("entry_filter.type", self._entry_types)
                if type_clause then
                    query_builder = query_builder:where(sql.builder.expr(unpack(type_clause)))
                end
            end

            if self._entry_statuses and #self._entry_statuses > 0 then
                local status_clause = create_in_clause("entry_filter.status", self._entry_statuses)
                if status_clause then
                    query_builder = query_builder:where(sql.builder.expr(unpack(status_clause)))
                end
            end
        else
            if self._entry_types and #self._entry_types > 0 then
                local type_clause = create_in_clause("e.type", self._entry_types)
                if type_clause then
                    query_builder = query_builder:where(sql.builder.expr(unpack(type_clause)))
                end
            end

            if self._entry_statuses and #self._entry_statuses > 0 then
                local status_clause = create_in_clause("e.status", self._entry_statuses)
                if status_clause then
                    query_builder = query_builder:where(sql.builder.expr(unpack(status_clause)))
                end
            end
        end
    end

    query_builder = query_builder:order_by("d.created_at DESC")

    -- Add secondary sorting for related data
    if self._include_categories then
        query_builder = query_builder:order_by("c.created_at ASC")
    end

    if self._include_entries then
        query_builder = query_builder:order_by("e.category_id, e.created_at ASC")
    end

    return query_builder
end

-- ============================================================================
-- RESULT PROCESSING
-- ============================================================================

local function group_joined_results(rows, fetch_metadata, fetch_content)
    local projects = {}
    local doc_map = {}

    for _, row in ipairs(rows) do
        local doc_id = row.project_id

        -- Create project if not exists
        if not doc_map[doc_id] then
            local doc = {
                project_id = row.project_id,
                user_id = row.user_id,
                project_type = row.project_type,
                title = row.title,
                status = row.status,
                created_at = row.created_at,
                updated_at = row.updated_at,
                categories = {},
                entries = {}
            }

            -- Handle project metadata based on fetch options
            if fetch_metadata then
                doc.metadata = row.metadata and parse_json_metadata(row.metadata) or {}
            end

            projects[#projects + 1] = doc
            doc_map[doc_id] = doc
        end

        local doc = doc_map[doc_id]

        -- Add category if present and not already added
        if row.category_id then
            local cat_exists = false
            for _, existing_cat in ipairs(doc.categories) do
                if existing_cat.category_id == row.category_id then
                    cat_exists = true
                    break
                end
            end

            if not cat_exists then
                local category = {
                    category_id = row.category_id,
                    project_id = row.project_id,
                    name = row.category_name,
                    display_name = row.category_display_name,
                    created_at = row.category_created_at
                }

                -- Handle category metadata based on fetch options
                if fetch_metadata then
                    category.metadata = row.category_metadata and parse_json_metadata(row.category_metadata) or {}
                end

                table.insert(doc.categories, category)
            end
        end

        -- Add entry if present and not already added
        if row.entry_id then
            local entry_exists = false
            for _, existing_entry in ipairs(doc.entries) do
                if existing_entry.entry_id == row.entry_id then
                    entry_exists = true
                    break
                end
            end

            if not entry_exists then
                local entry = {
                    entry_id = row.entry_id,
                    project_id = row.project_id,
                    category_id = row.entry_category_id,
                    type = row.entry_type,
                    content_type = row.entry_content_type,
                    title = row.entry_title,
                    status = row.entry_status,
                    created_at = row.entry_created_at,
                    updated_at = row.entry_updated_at
                }

                -- Handle entry content based on fetch options
                if fetch_content then
                    entry.content = row.entry_content
                end

                -- Handle entry metadata based on fetch options
                if fetch_metadata then
                    entry.metadata = row.entry_metadata and parse_json_metadata(row.entry_metadata) or {}
                end

                table.insert(doc.entries, entry)
            end
        end
    end

    return projects
end

-- ============================================================================
-- EXECUTION METHODS
-- ============================================================================

-- Get all matching projects with optional related data
function methods:all()
    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Use single query with JOINs when including related data
    if self._include_categories or self._include_entries then
        local query = self:_build_single_query_with_joins()
        local executor = query:run_with(db)
        local results, err = executor:query()

        if err then
            db:release()
            return nil, "Failed to fetch projects with joins: " .. err
        end

        db:release()

        -- Group the joined results
        local projects = group_joined_results(results, self._fetch_metadata, self._fetch_content)

        -- Clean up projects that don't need categories/entries
        for _, doc in ipairs(projects) do
            if not self._include_categories then
                doc.categories = nil
            end
            if not self._include_entries then
                doc.entries = nil
            end
        end

        return projects, nil
    else
        -- Use simple query when not including related data
        local docs_query = self:_build_projects_query()
        local docs_executor = docs_query:run_with(db)
        local docs_results, docs_err = docs_executor:query()

        if docs_err then
            db:release()
            return nil, "Failed to fetch projects: " .. docs_err
        end

        if self._fetch_metadata then
            docs_results = parse_metadata(docs_results)
        end

        db:release()
        return docs_results, nil
    end
end

-- Get a single project with optional related data
function methods:one()
    local results, err = self:all()
    if err then
        return nil, err
    end

    if #results == 0 then
        return nil, nil
    end

    return results[1], nil
end

-- Count matching projects
function methods:count()
    local query_builder = sql.builder.select("COUNT(DISTINCT d.project_id) as count")
        :from("drafling_projects d")
        :where("d.user_id = ?", self._user_id)

    -- Apply same filters as main query
    if self._project_ids and #self._project_ids > 0 then
        local doc_clause = create_in_clause("d.project_id", self._project_ids)
        if doc_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(doc_clause)))
        end
    end

    if self._project_types and #self._project_types > 0 then
        local type_clause = create_in_clause("d.project_type", self._project_types)
        if type_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(type_clause)))
        end
    end

    if self._project_statuses and #self._project_statuses > 0 then
        local status_clause = create_in_clause("d.status", self._project_statuses)
        if status_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(status_clause)))
        end
    end

    -- Apply category-based project filtering
    if self._category_names and #self._category_names > 0 then
        query_builder = query_builder
            :join("drafling_categories cat_filter ON cat_filter.project_id = d.project_id")

        local cat_clause = create_in_clause("cat_filter.name", self._category_names)
        if cat_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(cat_clause)))
        end
    end

    -- Apply entry-based project filtering
    if (self._entry_types and #self._entry_types > 0) or (self._entry_statuses and #self._entry_statuses > 0) then
        query_builder = query_builder
            :join("drafling_entries entry_filter ON entry_filter.project_id = d.project_id")

        if self._entry_types and #self._entry_types > 0 then
            local type_clause = create_in_clause("entry_filter.type", self._entry_types)
            if type_clause then
                query_builder = query_builder:where(sql.builder.expr(unpack(type_clause)))
            end
        end

        if self._entry_statuses and #self._entry_statuses > 0 then
            local status_clause = create_in_clause("entry_filter.status", self._entry_statuses)
            if status_clause then
                query_builder = query_builder:where(sql.builder.expr(unpack(status_clause)))
            end
        end
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local executor = query_builder:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        return nil, "Failed to count projects: " .. err
    end

    return results[1].count, nil
end

-- Check if matching projects exist
function methods:exists()
    local count, err = self:count()
    if err then
        return nil, err
    end
    return count > 0, nil
end

return doc_reader