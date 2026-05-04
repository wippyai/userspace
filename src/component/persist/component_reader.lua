local sql = require("sql")
local json = require("json")

-- Constants
local APP_DB = "app:db"

---@class ComponentReaderInstance
---@field _user_id string|nil
---@field _component_ids string[]|nil
---@field _impl_ids string[]|nil
---@field _meta_filters table|nil
---@field _access_mask_filter integer|nil
---@field _include_meta boolean
---@field _include_private_context boolean
---@field _include_access_level boolean
---@field _limit integer|nil
---@field _offset integer|nil
---@field _order_by string
---@field _order_direction string
---@field with_user fun(self: ComponentReaderInstance, user_id: string): ComponentReaderInstance
---@field with_components fun(self: ComponentReaderInstance, ...: string|string[]): ComponentReaderInstance
---@field with_impl_ids fun(self: ComponentReaderInstance, ...: string|string[]): ComponentReaderInstance
---@field with_meta fun(self: ComponentReaderInstance, meta_filters: table<string, string>): ComponentReaderInstance
---@field with_access_mask fun(self: ComponentReaderInstance, access_mask: integer): ComponentReaderInstance
---@field include fun(self: ComponentReaderInstance, options: IncludeOptions): ComponentReaderInstance
---@field paginate fun(self: ComponentReaderInstance, limit: integer, offset: integer|nil): ComponentReaderInstance
---@field order_by fun(self: ComponentReaderInstance, field: string, direction: string|nil): ComponentReaderInstance
---@field all fun(self: ComponentReaderInstance): ComponentResult[]
---@field one fun(self: ComponentReaderInstance): ComponentResult|nil
---@field count fun(self: ComponentReaderInstance): integer
---@field exists fun(self: ComponentReaderInstance): boolean

---@class ComponentResult
---@field component_id string
---@field impl_id string
---@field created_at string
---@field updated_at string
---@field private_context table|nil
---@field meta table|nil
---@field access_level integer|nil

---@class IncludeOptions
---@field meta boolean|nil
---@field private_context boolean|nil
---@field access_level boolean|nil

-- Create the module table
local component_reader = {}
local methods = {}
local reader_mt = { __index = methods }

---Helper to create an immutable copy of a reader
---@param self ComponentReaderInstance
---@return ComponentReaderInstance
function methods:_copy()
    local new_instance = {}
    for k, v in pairs(self) do
        new_instance[k] = v
    end
    return setmetatable(new_instance, reader_mt)
end

---Helper to normalize arguments from varargs or table
---@param args any[]
---@param arg_count integer
---@return string[]
local function normalize_args(args, arg_count)
    if arg_count == 1 and type(args[1]) == "table" and not getmetatable(args[1]) then
        return args[1] -- It's already a table
    else
        return args    -- Use the varargs as the array
    end
end

---Initialize a new reader for components
---@return ComponentReaderInstance
function component_reader.new()
    local instance = {
        _user_id = nil,
        _component_ids = nil,
        _impl_ids = nil,
        _meta_filters = nil,
        _access_mask_filter = nil,
        _include_meta = true,
        _include_private_context = false,
        _include_access_level = false,
        _limit = nil,
        _offset = nil,
        _order_by = "created_at",
        _order_direction = "DESC"
    }
    return setmetatable(instance, reader_mt)
end

---Filter by user ID (for access control)
---@param self ComponentReaderInstance
---@param user_id string
---@return ComponentReaderInstance
function methods:with_user(user_id)
    local new_instance = self:_copy()
    new_instance._user_id = user_id
    return new_instance
end

---Filter by specific component IDs
---@param self ComponentReaderInstance
---@param ... string|string[]
---@return ComponentReaderInstance
function methods:with_components(...)
    local args = { ... }
    local count = select("#", ...)
    local new_instance = self:_copy()
    new_instance._component_ids = normalize_args(args, count)
    return new_instance
end

---Filter by implementation IDs
---@param self ComponentReaderInstance
---@param ... string|string[]
---@return ComponentReaderInstance
function methods:with_impl_ids(...)
    local args = { ... }
    local count = select("#", ...)
    local new_instance = self:_copy()
    new_instance._impl_ids = normalize_args(args, count)
    return new_instance
end

---Filter by metadata key-value pairs
---Usage: :with_meta({class = "workflow", status = "active"})
---@param self ComponentReaderInstance
---@param meta_filters table<string, string>
---@return ComponentReaderInstance
function methods:with_meta(meta_filters)
    if not meta_filters or type(meta_filters) ~= "table" then
        return self
    end

    local new_instance = self:_copy()
    new_instance._meta_filters = meta_filters
    return new_instance
end

---Filter by access mask (user must have at least these permissions)
---@param self ComponentReaderInstance
---@param mask integer
---@return ComponentReaderInstance
function methods:with_access_mask(mask)
    local new_instance = self:_copy()
    new_instance._access_mask_filter = mask
    return new_instance
end

---Configure what data to include
---@param self ComponentReaderInstance
---@param options IncludeOptions
---@return ComponentReaderInstance
function methods:include_options(options)
    if not options or type(options) ~= "table" then
        return self
    end

    local new_instance = self:_copy()

    if options.meta ~= nil then
        new_instance._include_meta = options.meta
    end

    if options.private_context ~= nil then
        new_instance._include_private_context = options.private_context
    end

    if options.access_level ~= nil then
        new_instance._include_access_level = options.access_level
    end

    return new_instance
end

---Set pagination
---@param self ComponentReaderInstance
---@param limit integer
---@param offset integer|nil
---@return ComponentReaderInstance
function methods:limit(limit, offset)
    local new_instance = self:_copy()
    new_instance._limit = limit
    new_instance._offset = offset or 0
    return new_instance
end

---Set ordering
---@param self ComponentReaderInstance
---@param field string|nil
---@param direction string|nil
---@return ComponentReaderInstance
function methods:order_by(field, direction)
    local new_instance = self:_copy()
    new_instance._order_by = field or "created_at"
    new_instance._order_direction = direction or "DESC"
    return new_instance
end

---Helper function to create a parameterized IN clause
---@param field string
---@param values string[]
---@return table|nil
local function create_in_clause(field, values)
    if not values or #values == 0 then
        return nil
    end

    if #values == 1 then
        return { field .. " = ?", values[1] }
    end

    -- For multiple values, create a placeholders string like "?, ?, ?"
    local placeholders = {}
    for i = 1, #values do
        table.insert(placeholders, "?")
    end

    return { field .. " IN (" .. table.concat(placeholders, ", ") .. ")", unpack(values) }
end

---Build the SQL query based on current state
---@param self ComponentReaderInstance
---@return table
function methods:_build_query()
    local select_fields = { "c.component_id", "c.impl_id", "c.created_at", "c.updated_at" }

    -- Include private context if requested
    if self._include_private_context then
        table.insert(select_fields, "c.private_context")
    end

    -- Include access_mask if requested and user filtering is enabled
    if self._include_access_level and self._user_id then
        table.insert(select_fields, "ca.access_mask")
    end

    -- Start building the query
    local query_builder = sql.builder.select(unpack(select_fields))
        :from("components c")

    -- Join with access table if user_id is specified
    if self._user_id then
        query_builder = query_builder:inner_join("component_access ca ON c.component_id = ca.component_id")
        query_builder = query_builder:where("ca.user_id = ?", self._user_id)

        -- Apply access mask filter if specified
        if self._access_mask_filter then
            query_builder = query_builder:where("(ca.access_mask & ?) = ?", self._access_mask_filter,
                self._access_mask_filter)
        end
    end

    -- Add component ID filtering
    if self._component_ids and #self._component_ids > 0 then
        local id_clause = create_in_clause("c.component_id", self._component_ids :: any)
        if id_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(id_clause)))
        end
    end

    -- Add implementation ID filtering
    if self._impl_ids and #self._impl_ids > 0 then
        local impl_clause = create_in_clause("c.impl_id", self._impl_ids :: any)
        if impl_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(impl_clause)))
        end
    end

    -- FIXED: Add metadata filtering if specified (removed dependency on _include_meta)
    if self._meta_filters then
        for key, value in pairs(self._meta_filters) do
            query_builder = query_builder:where(sql.builder.expr(
                "c.component_id IN (SELECT component_id FROM component_meta WHERE key = ? AND value = ?)",
                key, value
            ))
        end
    end

    -- Add ordering
    local order_field = "c." .. self._order_by
    query_builder = query_builder:order_by(order_field .. " " .. self._order_direction)

    -- Add pagination
    if self._limit then
        query_builder = query_builder:limit(self._limit :: number)
        if self._offset and self._offset > 0 then
            query_builder = query_builder:offset(self._offset)
        end
    end

    return query_builder
end

---Parse JSON private context
---@param context_str string|nil
---@return table
local function parse_private_context(context_str)
    if not context_str or type(context_str) ~= "string" then
        return {}
    end

    local success, parsed = pcall(json.decode, context_str)
    if success then
        return parsed
    else
        return {}
    end
end

---Load metadata for components
---@param db table
---@param component_ids string[]
---@return table<string, table<string, string>>
local function load_metadata(db, component_ids)
    if not component_ids or #component_ids == 0 then
        return {}
    end

    local meta_clause = create_in_clause("component_id", component_ids)
    if not meta_clause then
        return {}
    end

    local meta_query = sql.builder.select("component_id", "key", "value")
        :from("component_meta")
        :where(sql.builder.expr(unpack(meta_clause)))
        :order_by("component_id, key")

    local executor = meta_query:run_with(db)
    local meta_rows, err = executor:query()

    if err then
        error("Failed to load component metadata: " .. err)
    end

    -- Group metadata by component_id
    local metadata_map = {}
    for _, row in ipairs(meta_rows or {}) do
        if not metadata_map[row.component_id] then
            metadata_map[row.component_id] = {}
        end
        metadata_map[row.component_id][row.key] = row.value
    end

    return metadata_map
end

---Helper to get database connection
---@return table
local function get_db()
    local db, err = sql.get(APP_DB)
    if err then
        error("Failed to connect to database: " .. err)
    end
    return db
end

---Get all matching components
---@param self ComponentReaderInstance
---@return ComponentResult[]
function methods:all()
    local query_builder = self:_build_query()
    local db = get_db()

    local executor = query_builder:run_with(db)
    local results, err = executor:query()

    if err then
        db:release()
        error("Failed to fetch components: " .. err)
    end

    -- Load metadata if requested
    local metadata_map = {}
    if self._include_meta and results and #results > 0 then
        local component_ids = {}
        for _, component in ipairs(results) do
            table.insert(component_ids, component.component_id)
        end
        metadata_map = load_metadata(db, component_ids :: any)
    end

    db:release()

    -- Process results
    for i, component in ipairs(results or {}) do
        -- Parse private context if included
        if self._include_private_context and component.private_context then
            component.private_context = parse_private_context(component.private_context)
        end

        -- Set access_level from access_mask if included
        if self._include_access_level and component.access_mask ~= nil then
            component.access_level = component.access_mask
            component.access_mask = nil  -- Remove the raw field
        end

        -- Add metadata if included
        if self._include_meta then
            component.meta = metadata_map[component.component_id] or {}
        end
    end

    return results or {}
end

---Get a single component
---@param self ComponentReaderInstance
---@return ComponentResult|nil
function methods:one()
    local query_builder = self:_build_query():limit(1)
    local db = get_db()

    local executor = query_builder:run_with(db)
    local results, err = executor:query()

    if err then
        db:release()
        error("Failed to fetch component: " .. err)
    end

    if not results or #results == 0 then
        db:release()
        return nil
    end

    local component = results[1]

    -- Load metadata if requested
    if self._include_meta then
        local metadata_map = load_metadata(db, { component.component_id })
        component.meta = metadata_map[component.component_id] or {}
    end

    db:release()

    -- Parse private context if included
    if self._include_private_context and component.private_context then
        component.private_context = parse_private_context(component.private_context)
    end

    -- Set access_level from access_mask if included
    if self._include_access_level and component.access_mask ~= nil then
        component.access_level = component.access_mask
        component.access_mask = nil  -- Remove the raw field
    end

    return component
end

---Count matching components
---@param self ComponentReaderInstance
---@return integer
function methods:count()
    -- Build a count query based on the same filters
    local query_builder = sql.builder.select("COUNT(DISTINCT c.component_id) as count")
        :from("components c")

    -- Apply same joins and filters as main query
    if self._user_id then
        query_builder = query_builder:inner_join("component_access ca ON c.component_id = ca.component_id")
        query_builder = query_builder:where("ca.user_id = ?", self._user_id)

        if self._access_mask_filter then
            query_builder = query_builder:where("(ca.access_mask & ?) = ?", self._access_mask_filter,
                self._access_mask_filter)
        end
    end

    if self._component_ids and #self._component_ids > 0 then
        local id_clause = create_in_clause("c.component_id", self._component_ids :: any)
        if id_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(id_clause)))
        end
    end

    if self._impl_ids and #self._impl_ids > 0 then
        local impl_clause = create_in_clause("c.impl_id", self._impl_ids :: any)
        if impl_clause then
            query_builder = query_builder:where(sql.builder.expr(unpack(impl_clause)))
        end
    end

    -- FIXED: Add metadata filtering if specified (removed dependency on _include_meta)
    if self._meta_filters then
        for key, value in pairs(self._meta_filters) do
            query_builder = query_builder:where(sql.builder.expr(
                "c.component_id IN (SELECT component_id FROM component_meta WHERE key = ? AND value = ?)",
                key, value
            ))
        end
    end

    local db = get_db()
    local executor = query_builder:run_with(db)
    local results, err = executor:query()
    db:release()

    if err then
        error("Failed to count components: " .. err)
    end

    return results[1].count
end

---Check if matching components exist
---@param self ComponentReaderInstance
---@return boolean
function methods:exists()
    return self:count() > 0
end

return component_reader
