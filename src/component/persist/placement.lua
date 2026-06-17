-- placement: hierarchy + ordering engine for the components table.
--
-- Two backend-specific representations of the ancestor path, one logical model:
--   postgres: ltree column. Labels are component UUIDs with hyphens stripped
--             (32 hex chars = a valid ltree label). Ancestor/descendant via @>/<@.
--   sqlite:   materialized TEXT path "/<id>/<id>/" queried via LIKE prefix.
--
-- Ordering uses a lexorank string (fractional, midpoint between neighbors) so a
-- reorder is O(1): only the moved row's position changes. Read/query helpers
-- return values plus a typed error?; they never raise so the caller's
-- transaction keeps control of rollback.

local sql = require("sql")
local consts = require("userspace_component_consts")

local M = {}

-- A pooled connection or an open transaction; every helper reads through either.
type Executor = sql.DB | sql.Transaction

-- One placement row as read back.
type Node = {
    component_id: string,
    parent_id: string?,
    position: string?,
    path: string?,
}

-- lexorank alphabet: digits then lowercase letters, ordered by byte value.
local ALPHABET = consts.LEXORANK.ALPHABET
local BASE = #ALPHABET
local MIN_CHAR = ALPHABET:sub(1, 1)       -- "0"
local MAX_CHAR = ALPHABET:sub(BASE, BASE) -- "z"

local function char_index(c: string): integer
    return (ALPHABET:find(c, 1, true) or 1) - 1
end

local function index_char(i: integer): string
    return ALPHABET:sub(i + 1, i + 1)
end

-- Midpoint rank strictly between lo and hi (either may be nil = open bound).
-- Returns a string that sorts after lo and before hi byte-wise.
function M.rank_between(lo: string?, hi: string?): string
    local lo_s = lo or ""
    local hi_s = hi or ""

    local result: string[] = {}
    local i = 1
    while true do
        local lo_c = i <= #lo_s and lo_s:sub(i, i) or MIN_CHAR
        local hi_c = i <= #hi_s and hi_s:sub(i, i) or (hi_s == "" and MAX_CHAR or MIN_CHAR)

        if hi_s == "" then
            hi_c = MAX_CHAR
        end

        local lo_i = char_index(lo_c)
        local hi_i = char_index(hi_c)

        if lo_i == hi_i then
            result[i] = index_char(lo_i)
            i = i + 1
        else
            local mid = math.floor((lo_i + hi_i) / 2)
            if mid > lo_i then
                result[i] = index_char(mid)
                return table.concat(result)
            end
            -- Neighbors are adjacent: keep lo's char and descend a level.
            result[i] = index_char(lo_i)
            i = i + 1
            -- Append a midpoint above the implicit MIN of lo's next level.
            local next_lo = (i <= #lo_s) and char_index(lo_s:sub(i, i)) or 0
            result[i] = index_char(math.floor((next_lo + BASE) / 2))
            return table.concat(result)
        end
    end
    -- Unreachable: the loop returns once lo and hi diverge.
    return table.concat(result)
end

local function is_postgres(db: Executor): boolean
    return (db :: sql.DB):type() == sql.type.POSTGRES
end

-- ltree label for a component: uuid with hyphens stripped (32 hex chars).
local function ltree_label(component_id: string): string
    return (component_id:gsub("%-", ""))
end

-- Build the stored path for a node given its parent's stored path (or nil/root).
-- postgres: parent_path .. "." .. label ; root = label
-- sqlite:   parent_path .. id .. "/"     ; root = "/" .. id .. "/"
function M.build_path(db: Executor, component_id: string, parent_path: string?): string
    if is_postgres(db) then
        local label = ltree_label(component_id)
        if parent_path and parent_path ~= "" then
            return parent_path .. "." .. label
        end
        return label
    end
    local sep = consts.PATH_SEPARATOR
    if parent_path and parent_path ~= "" then
        return parent_path .. component_id .. sep
    end
    return sep .. component_id .. sep
end

-- Read a component's stored parent_id, position, path within a tx.
function M.read_node(tx: Executor, component_id: string): (Node?, error?)
    local rows, err = sql.builder.select("component_id", "parent_id", "position", "path")
        :from(consts.TABLES.COMPONENTS)
        :where("component_id = ?", component_id)
        :limit(1)
        :run_with(tx):query()
    if err then
        return nil, (errors.new({ message = "placement read_node failed: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end
    if not rows or #rows == 0 then
        return nil, nil
    end
    return rows[1] :: Node, nil
end

-- Largest sibling position under parent_id (nil parent = root). Used to append.
function M.max_sibling_position(tx: Executor, parent_id: string?): (string?, error?)
    local q = sql.builder.select("position")
        :from(consts.TABLES.COMPONENTS)
        :order_by("position DESC")
        :limit(1)
    if parent_id == nil then
        q = q:where("parent_id IS NULL")
    else
        q = q:where("parent_id = ?", parent_id)
    end
    local rows, err = q:run_with(tx):query()
    if err then
        return nil, (errors.new({ message = "placement max_sibling_position failed: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end
    if rows and #rows > 0 and rows[1].position ~= nil then
        return rows[1].position :: string, nil
    end
    return nil, nil
end

-- Descendants of a node (excluding the node itself), as { component_id, path }.
function M.descendants(tx: Executor, db: Executor, node_path: string?): (Node[]?, error?)
    if not node_path or node_path == "" then
        return {}, nil
    end
    local rows, err
    if is_postgres(db) then
        -- node_path @> path matches the node and its descendants; exclude self.
        rows, err = sql.builder.select("component_id", "path")
            :from(consts.TABLES.COMPONENTS)
            :where("path <@ ?", node_path)
            :where("path <> ?", node_path)
            :run_with(tx):query()
    else
        rows, err = sql.builder.select("component_id", "path")
            :from(consts.TABLES.COMPONENTS)
            :where("path LIKE ?", node_path .. "%")
            :where("path <> ?", node_path)
            :run_with(tx):query()
    end
    if err then
        return nil, (errors.new({ message = "placement descendants failed: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end
    return (rows or {}) :: Node[], nil
end

-- Is candidate_id the node itself or one of its descendants? Used for cycle guard.
function M.is_self_or_descendant(tx: Executor, db: Executor, node_path: string?, candidate_id: string): (boolean, error?)
    if not node_path or node_path == "" then
        return false, nil
    end
    local rows, err
    if is_postgres(db) then
        rows, err = sql.builder.select("component_id")
            :from(consts.TABLES.COMPONENTS)
            :where("path <@ ?", node_path)
            :where("component_id = ?", candidate_id)
            :limit(1)
            :run_with(tx):query()
    else
        rows, err = sql.builder.select("component_id")
            :from(consts.TABLES.COMPONENTS)
            :where("path LIKE ?", node_path .. "%")
            :where("component_id = ?", candidate_id)
            :limit(1)
            :run_with(tx):query()
    end
    if err then
        return false, (errors.new({ message = "placement cycle check failed: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end
    return rows ~= nil and #rows > 0, nil
end

return M
