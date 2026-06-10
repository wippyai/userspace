-- component_reader: a fluent, immutable query builder over the component tables.
-- Builder methods return a new reader; terminal methods (all/one/count/exists)
-- own a pooled connection for their single call, release it on every return
-- path, and return (value, error?) — errors are structured via the global errors
-- module and never raised, so callers stay in control of flow.

local sql = require("sql")
local json = require("json")
local access_subjects = require("access_subjects")
local consts = require("consts")

-- Include flags + filters that make up a reader's immutable state.
type ReaderState = {
    _user_id: string?,
    _component_ids: string[]?,
    _impl_ids: string[]?,
    _meta_filters: { [string]: string }?,
    _access_mask_filter: integer?,
    _parent_id: string?,
    _parent_is_null: boolean,
    _path_prefix: string?,
    _include_meta: boolean,
    _include_private_context: boolean,
    _include_access_level: boolean,
    _include_placement: boolean,
    _limit: integer?,
    _offset: integer?,
    _order_by: string,
    _order_direction: string,
    _order_by_position: boolean,
}

-- One component row as read back. Optional fields are populated only when the
-- matching include flag is set. private_context/meta are open JSON leaves.
type ComponentResult = {
    component_id: string,
    impl_id: string,
    created_at: string,
    updated_at: string,
    private_context: { [string]: any }?, -- open private config blob
    meta: { [string]: string }?,
    access_level: integer?,
    parent_id: string?,
    position: string?,
    path: string?,
}

-- Which extra columns/joins to populate.
type IncludeOptions = {
    meta: boolean?,
    private_context: boolean?,
    access_level: boolean?,
    placement: boolean?,
}

local component_reader = {}
local methods = {}
local reader_mt = { __index = methods }

-- Immutable copy of a reader for the next builder step.
function methods:_copy(): ReaderState
    local new_instance = {}
    for k, v in pairs(self) do
        new_instance[k] = v
    end
    return setmetatable(new_instance, reader_mt) :: ReaderState
end

-- Normalize varargs/array args into a string list.
local function normalize_args(args: any[], arg_count: integer): string[]
    if arg_count == 1 and type(args[1]) == "table" and not getmetatable(args[1]) then
        return args[1] :: string[]
    end
    return args :: string[]
end

-- Initialize a new reader for components.
function component_reader.new(): ReaderState
    local instance = {
        _user_id = nil,
        _component_ids = nil,
        _impl_ids = nil,
        _meta_filters = nil,
        _access_mask_filter = nil,
        _parent_id = nil,
        _parent_is_null = false,
        _path_prefix = nil,
        _include_meta = true,
        _include_private_context = false,
        _include_access_level = false,
        _include_placement = false,
        _limit = nil,
        _offset = nil,
        _order_by = consts.DEFAULTS.ORDER_BY,
        _order_direction = consts.DEFAULTS.ORDER_DIRECTION,
        _order_by_position = false,
    }
    return setmetatable(instance, reader_mt) :: ReaderState
end

-- Filter by user ID (for access control).
function methods:with_user(user_id: string): ReaderState
    local new_instance = self:_copy()
    new_instance._user_id = user_id
    return new_instance
end

-- Filter by specific component IDs (varargs or a single array).
function methods:with_components(...): ReaderState
    local args = { ... }
    local count = select("#", ...)
    local new_instance = self:_copy()
    new_instance._component_ids = normalize_args(args, count)
    return new_instance
end

-- Filter by implementation IDs (varargs or a single array).
function methods:with_impl_ids(...): ReaderState
    local args = { ... }
    local count = select("#", ...)
    local new_instance = self:_copy()
    new_instance._impl_ids = normalize_args(args, count)
    return new_instance
end

-- Filter by metadata key-value pairs (all must match).
function methods:with_meta(meta_filters: { [string]: string }?): ReaderState
    if not meta_filters or type(meta_filters) ~= "table" then
        return self :: ReaderState
    end
    local new_instance = self:_copy()
    new_instance._meta_filters = meta_filters
    return new_instance
end

-- Filter by access mask (user must have at least these permissions).
function methods:with_access_mask(mask: integer): ReaderState
    local new_instance = self:_copy()
    new_instance._access_mask_filter = mask
    return new_instance
end

-- Filter by parent id. Pass nil to scope to root-level components.
function methods:with_parent(parent_id: string?): ReaderState
    local new_instance = self:_copy()
    if parent_id == nil then
        new_instance._parent_id = nil
        new_instance._parent_is_null = true
    else
        new_instance._parent_id = parent_id
        new_instance._parent_is_null = false
    end
    return new_instance
end

-- Filter to components whose stored path is the given prefix or below it. The
-- prefix must be a stored path value (sqlite materialized path or pg ltree).
function methods:with_path_prefix(path_prefix: string): ReaderState
    local new_instance = self:_copy()
    new_instance._path_prefix = path_prefix
    return new_instance
end

-- Configure what data to include.
function methods:include_options(options: IncludeOptions): ReaderState
    if not options or type(options) ~= "table" then
        return self :: ReaderState
    end

    local new_instance = self:_copy()
    if options.meta ~= nil then new_instance._include_meta = options.meta end
    if options.private_context ~= nil then new_instance._include_private_context = options.private_context end
    if options.access_level ~= nil then new_instance._include_access_level = options.access_level end
    if options.placement ~= nil then new_instance._include_placement = options.placement end
    return new_instance
end

-- Set pagination.
function methods:limit(limit: integer, offset: integer?): ReaderState
    local new_instance = self:_copy()
    new_instance._limit = limit
    new_instance._offset = offset or 0
    return new_instance
end

-- Set ordering.
function methods:order_by(field: string?, direction: string?): ReaderState
    local new_instance = self:_copy()
    new_instance._order_by = field or consts.DEFAULTS.ORDER_BY
    new_instance._order_direction = direction or consts.DEFAULTS.ORDER_DIRECTION
    new_instance._order_by_position = false
    return new_instance
end

-- Order by sibling position (lexorank), then created_at for stability.
function methods:order_by_position(): ReaderState
    local new_instance = self:_copy()
    new_instance._order_by_position = true
    return new_instance
end

-- Build a parameterized IN clause as { sql_fragment, value1, value2, ... }.
local function create_in_clause(field: string, values: string[]?): any[]?
    if not values or #values == 0 then
        return nil
    end
    if #values == 1 then
        return { field .. " = ?", values[1] }
    end
    local placeholders: string[] = {}
    for i = 1, #values do
        placeholders[i] = "?"
    end
    return { field .. " IN (" .. table.concat(placeholders, ", ") .. ")", unpack(values) }
end

-- Scope a query to components a user can access. Subjects (user + their groups)
-- come from access_subjects.
local function apply_access_join(query_builder: any, user_id: string, component_ids: string[]?, access_mask_filter: integer?): any
    local subjects = access_subjects.resolve(user_id)

    if #subjects == 1 then
        -- No groups: a direct, index-backed join.
        query_builder = query_builder:inner_join(consts.TABLES.ACCESS .. " ca ON c.component_id = ca.component_id")
        query_builder = query_builder:where("ca.user_id = ?", subjects[1])
    else
        -- User + groups: aggregate to one row per component (MAX(access_mask)) so
        -- multiple grants neither duplicate rows nor under-report access. When the
        -- caller scopes to specific component ids, push that filter into the
        -- aggregation so single-component checks stay O(1).
        local args: any[] = {}
        for _, s in ipairs(subjects) do args[#args + 1] = s end
        local where_sql = "user_id IN (" .. access_subjects.placeholders(subjects) .. ")"
        if component_ids and #component_ids > 0 then
            where_sql = where_sql .. " AND component_id IN (" .. access_subjects.placeholders(component_ids) .. ")"
            for _, cid in ipairs(component_ids) do args[#args + 1] = cid end
        end
        local join_sql = "(SELECT component_id, MAX(access_mask) AS access_mask FROM " .. consts.TABLES.ACCESS .. " WHERE "
            .. where_sql
            .. " GROUP BY component_id) ca ON c.component_id = ca.component_id"
        query_builder = query_builder:inner_join(join_sql, unpack(args))
    end

    if access_mask_filter then
        query_builder = query_builder:where("(ca.access_mask & ?) = ?", access_mask_filter, access_mask_filter)
    end

    return query_builder
end

-- Apply placement filters shared by main and count queries.
function methods:_apply_placement_filters(query_builder: any): any
    local self = self :: ReaderState
    if self._parent_is_null then
        query_builder = query_builder:where("c.parent_id IS NULL")
    elseif self._parent_id then
        query_builder = query_builder:where("c.parent_id = ?", self._parent_id)
    end

    if self._path_prefix then
        if self._path_prefix:find(consts.PATH_SEPARATOR, 1, true) then
            -- sqlite materialized path
            query_builder = query_builder:where("c.path LIKE ?", self._path_prefix .. "%")
        else
            -- pg ltree path label
            query_builder = query_builder:where("c.path <@ ?", self._path_prefix)
        end
    end

    return query_builder
end

-- Apply id / impl / meta filters shared by main and count queries.
function methods:_apply_filters(query_builder: any): any
    local self = self :: ReaderState
    if self._component_ids and #self._component_ids > 0 then
        local id_clause = create_in_clause("c.component_id", self._component_ids)
        if id_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(id_clause)))
        end
    end

    if self._impl_ids and #self._impl_ids > 0 then
        local impl_clause = create_in_clause("c.impl_id", self._impl_ids)
        if impl_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(impl_clause)))
        end
    end

    if self._meta_filters then
        for key, value in pairs(self._meta_filters) do
            query_builder = query_builder:where(sql.builder.expr(
                "c.component_id IN (SELECT component_id FROM " .. consts.TABLES.META .. " WHERE key = ? AND value = ?)",
                key, value
            ))
        end
    end

    return self:_apply_placement_filters(query_builder)
end

-- Build the main SELECT query based on current state.
function methods:_build_query(): any
    local self = self :: ReaderState
    local select_fields = { "c.component_id", "c.impl_id", "c.created_at", "c.updated_at" }

    if self._include_private_context then
        table.insert(select_fields, "c.private_context")
    end
    if self._include_placement then
        table.insert(select_fields, "c.parent_id")
        table.insert(select_fields, "c.position")
        table.insert(select_fields, "c.path")
    end
    if self._include_access_level and self._user_id then
        table.insert(select_fields, "ca.access_mask")
    end

    local query_builder = sql.builder.select(unpack(select_fields)):from(consts.TABLES.COMPONENTS .. " c")

    if self._user_id then
        query_builder = apply_access_join(query_builder, self._user_id, self._component_ids, self._access_mask_filter)
    end

    query_builder = self:_apply_filters(query_builder)

    if self._order_by_position then
        query_builder = query_builder:order_by("c.position ASC")
        query_builder = query_builder:order_by("c.created_at ASC")
    else
        query_builder = query_builder:order_by("c." .. self._order_by .. " " .. self._order_direction)
    end

    if self._limit then
        query_builder = query_builder:limit(self._limit)
        if self._offset and self._offset > 0 then
            query_builder = query_builder:offset(self._offset)
        end
    end

    return query_builder
end

-- Parse a stored JSON private context into a table; an unparseable value yields
-- an empty table so a malformed row never breaks the read.
local function parse_private_context(context_str: any): { [string]: any }
    if not context_str or type(context_str) ~= "string" then
        return {}
    end
    local ok, parsed = pcall(json.decode, context_str)
    if ok and type(parsed) == "table" then
        return parsed :: { [string]: any }
    end
    return {}
end

-- Load metadata for components keyed by component_id.
local function load_metadata(db: any, component_ids: string[]): ({ [string]: { [string]: string } }?, error?)
    if not component_ids or #component_ids == 0 then
        return {}, nil
    end

    local meta_clause = create_in_clause("component_id", component_ids)
    if not meta_clause then
        return {}, nil
    end

    local meta_rows, err = sql.builder.select("component_id", "key", "value")
        :from(consts.TABLES.META)
        :where(sql.builder.expr(unpack(meta_clause)))
        :order_by("component_id, key")
        :run_with(db):query()
    if err then
        return nil, (errors.new({ message = "failed to load component metadata: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    local metadata_map: { [string]: { [string]: string } } = {}
    for _, row in ipairs(meta_rows or {}) do
        if not metadata_map[row.component_id] then
            metadata_map[row.component_id] = {}
        end
        metadata_map[row.component_id][row.key] = row.value
    end
    return metadata_map, nil
end

-- Open a pooled connection for a single terminal call.
local function get_db(): (any, error?)
    local db, err = sql.get(consts.DB_RESOURCE)
    if err or not db then
        return nil, (errors.new({ message = "failed to connect to database: " .. tostring(err), kind = errors.UNAVAILABLE }) :: error)
    end
    return db, nil
end

-- Decode private context and project the access mask into access_level.
function methods:_finalize_row(component: ComponentResult)
    if self._include_private_context and component.private_context then
        component.private_context = parse_private_context(component.private_context)
    end
    local raw = component :: any
    if self._include_access_level and raw.access_mask ~= nil then
        component.access_level = raw.access_mask
        raw.access_mask = nil
    end
end

-- Get all matching components.
function methods:all(): (ComponentResult[]?, error?)
    local db, db_err = get_db()
    if db_err then
        return nil, db_err
    end

    local results, err = self:_build_query():run_with(db):query()
    if err then
        db:release()
        return nil, (errors.new({ message = "failed to fetch components: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    local metadata_map: { [string]: { [string]: string } } = {}
    if self._include_meta and results and #results > 0 then
        local component_ids: string[] = {}
        for _, component in ipairs(results) do
            component_ids[#component_ids + 1] = component.component_id
        end
        local loaded, meta_err = load_metadata(db, component_ids)
        if meta_err then
            db:release()
            return nil, meta_err
        end
        metadata_map = loaded or {}
    end

    db:release()

    for _, component in ipairs(results or {}) do
        self:_finalize_row(component :: ComponentResult)
        if self._include_meta then
            component.meta = metadata_map[component.component_id] or {}
        end
    end

    return (results or {}) :: ComponentResult[], nil
end

-- Get a single component (nil, nil when none match).
function methods:one(): (ComponentResult?, error?)
    local db, db_err = get_db()
    if db_err then
        return nil, db_err
    end

    local results, err = self:_build_query():limit(1):run_with(db):query()
    if err then
        db:release()
        return nil, (errors.new({ message = "failed to fetch component: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    if not results or #results == 0 then
        db:release()
        return nil, nil
    end

    local component = results[1]

    if self._include_meta then
        local metadata_map, meta_err = load_metadata(db, { component.component_id :: string })
        if meta_err then
            db:release()
            return nil, meta_err
        end
        component.meta = (metadata_map or {})[component.component_id] or {}
    end

    db:release()

    self:_finalize_row(component :: ComponentResult)
    return component :: ComponentResult, nil
end

-- Count matching components.
function methods:count(): (integer?, error?)
    local self = self :: ReaderState
    local query_builder = sql.builder.select("COUNT(DISTINCT c.component_id) as count")
        :from(consts.TABLES.COMPONENTS .. " c")

    if self._user_id then
        query_builder = apply_access_join(query_builder, self._user_id, self._component_ids, self._access_mask_filter)
    end

    query_builder = self:_apply_filters(query_builder)

    local db, db_err = get_db()
    if db_err then
        return nil, db_err
    end
    local results, err = query_builder:run_with(db):query()
    db:release()
    if err then
        return nil, (errors.new({ message = "failed to count components: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    return results[1].count :: integer, nil
end

-- Check if matching components exist.
function methods:exists(): (boolean, error?)
    local n, err = self:count()
    if err then
        return false, err
    end
    return (n or 0) > 0, nil
end

return component_reader
