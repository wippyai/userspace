-- ops: transaction-scoped command handlers for the component tables plus the
-- access-check and subtree-grant helpers. Every handler takes the caller's tx
-- (and db for dialect detection where paths must re-materialize) and returns
-- (result, error?); errors are structured via the global errors module and never
-- raised, so a caller-managed transaction stays in control of rollback.

local sql = require("sql")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local access_subjects = require("access_subjects")
local placement = require("placement")
local consts = require("consts")

-- A pooled connection or an open transaction.
type Executor = sql.DB | sql.Transaction

-- A command dispatched to a handler. payload shape varies per command type and
-- is open JSON validated by each handler, so it stays an open map.
type Command = {
    type: string,
    payload: { [string]: any }?, -- handler-specific fields; validated per type
}

-- Result returned by a handler. Fields present depend on the command; an open
-- map keeps the shared dispatch (update_component) generic across command types.
type CommandResult = { [string]: any } -- handler-specific fields

-- A grant/revoke subject: a user id or a group id (the access table stores both
-- in its user_id column; access_subjects resolves a user into user + groups).
type Subject = string

-- Define command handlers for component operations.
type Handler = (Executor, Executor, Command) -> (CommandResult?, error?)
local handlers: { [string]: Handler } = {}

-- Encode a private-context value to its stored JSON string.
local function encode_context(value: any): (string?, error?)
    if type(value) ~= "table" then
        return tostring(value), nil
    end
    local encoded, err = json.encode(value)
    if err then
        return nil, (errors.new({ message = "failed to encode private context: " .. tostring(err), kind = errors.INVALID }) :: error)
    end
    return encoded, nil
end

-- CREATE_COMPONENT payload: { component_id?, impl_id, private_context?,
-- initial_meta?, owner_user_id, parent_id?, position? }. parent_id omitted =>
-- root; position omitted => append after last sibling.
handlers[consts.COMMAND_TYPES.CREATE_COMPONENT] = function(tx: Executor, db: Executor, command: Command): (CommandResult?, error?)
    local payload = command.payload or {}

    if not payload.impl_id or payload.impl_id == "" then
        return nil, (errors.new({ message = "implementation ID is required", kind = errors.INVALID }) :: error)
    end
    if not payload.owner_user_id or payload.owner_user_id == "" then
        return nil, (errors.new({ message = "owner user ID is required", kind = errors.INVALID }) :: error)
    end

    local component_id = (payload.component_id or uuid.v7()) :: string

    local private_context, enc_err = encode_context(payload.private_context or {})
    if enc_err then
        return nil, enc_err
    end

    local now_ts = time.now():format(time.RFC3339NANO)

    -- Resolve parent and materialize the stored path.
    local parent_id = payload.parent_id :: string?
    local parent_path: string? = nil
    if parent_id ~= nil and parent_id ~= "" then
        local parent, perr = placement.read_node(tx, parent_id)
        if perr then
            return nil, perr
        end
        if not parent then
            return nil, (errors.new({ message = "parent component not found", kind = errors.NOT_FOUND }) :: error)
        end
        parent_path = parent.path
    else
        parent_id = nil
    end

    local node_path = placement.build_path(db, component_id, parent_path)

    -- Resolve sibling position: explicit, else append after last sibling.
    local position = payload.position
    if position == nil or position == "" then
        local last, lerr = placement.max_sibling_position(tx, parent_id)
        if lerr then
            return nil, lerr
        end
        position = placement.rank_between(last, nil)
    end

    local _, err = sql.builder.insert(consts.TABLES.COMPONENTS)
        :set_map({
            component_id = component_id,
            impl_id = payload.impl_id,
            private_context = private_context,
            parent_id = parent_id,
            position = position,
            path = node_path,
            created_at = now_ts,
            updated_at = now_ts,
        })
        :run_with(tx):exec()
    if err then
        return nil, (errors.new({ message = "failed to create component: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    -- Grant full access to the owner.
    local _, access_err = sql.builder.insert(consts.TABLES.ACCESS)
        :set_map({
            access_id = uuid.v7(),
            user_id = payload.owner_user_id,
            component_id = component_id,
            access_mask = consts.ACCESS.FULL,
            created_at = now_ts,
        })
        :run_with(tx):exec()
    if access_err then
        return nil, (errors.new({ message = "failed to create component access: " .. tostring(access_err), kind = errors.INTERNAL }) :: error)
    end

    -- Add initial metadata if provided.
    if payload.initial_meta and type(payload.initial_meta) == "table" then
        for key, value in pairs(payload.initial_meta) do
            local _, meta_err = sql.builder.insert(consts.TABLES.META)
                :set_map({
                    meta_id = uuid.v7(),
                    component_id = component_id,
                    key = key,
                    value = tostring(value),
                    created_at = now_ts,
                    updated_at = now_ts,
                })
                :run_with(tx):exec()
            if meta_err then
                return nil, (errors.new({ message = "failed to create initial metadata: " .. tostring(meta_err), kind = errors.INTERNAL }) :: error)
            end
        end
    end

    return { component_id = component_id, changes_made = true }, nil
end

-- Re-root one former-direct-child subtree to the database root: clear its
-- parent, rewrite its path to a fresh root path, then rewrite each of its
-- descendants by swapping the old subtree prefix for the new one. parent_id is
-- nulled explicitly rather than relying on the FK action, since per-connection
-- SQLite FK enforcement is off; the FK ON DELETE SET NULL is the safety net.
local function reroot_subtree(tx: Executor, db: Executor, child_id: string, child_old_path: string): error?
    local new_root_path = placement.build_path(db, child_id, nil)

    local _, uerr = sql.builder.update(consts.TABLES.COMPONENTS)
        :set("parent_id", sql.as.null())
        :set("path", new_root_path)
        :where("component_id = ?", child_id)
        :run_with(tx):exec()
    if uerr then
        return (errors.new({ message = "failed to re-root child: " .. tostring(uerr), kind = errors.INTERNAL }) :: error)
    end

    local descendants, derr = placement.descendants(tx, db, child_old_path)
    if derr then
        return derr
    end
    for _, d in ipairs(descendants or {}) do
        local d_new = new_root_path .. tostring(d.path):sub(#child_old_path + 1)
        local _, dperr = sql.builder.update(consts.TABLES.COMPONENTS)
            :set("path", d_new)
            :where("component_id = ?", d.component_id)
            :run_with(tx):exec()
        if dperr then
            return (errors.new({ message = "failed to re-materialize descendant path: " .. tostring(dperr), kind = errors.INTERNAL }) :: error)
        end
    end
    return nil
end

-- DELETE_COMPONENT payload: { component_id }. Direct children are orphaned to
-- root with re-materialized paths; subtrees are never cascade-deleted.
handlers[consts.COMMAND_TYPES.DELETE_COMPONENT] = function(tx: Executor, db: Executor, command: Command): (CommandResult?, error?)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end

    -- Capture direct children before deletion so each subtree can be explicitly
    -- orphaned to root (parent_id NULL) with re-materialized paths afterward.
    local children, cerr = sql.builder.select("component_id", "path")
        :from(consts.TABLES.COMPONENTS)
        :where("parent_id = ?", payload.component_id)
        :run_with(tx):query()
    if cerr then
        return nil, (errors.new({ message = "failed to read children: " .. tostring(cerr), kind = errors.INTERNAL }) :: error)
    end

    local result, err = sql.builder.delete(consts.TABLES.COMPONENTS)
        :where("component_id = ?", payload.component_id)
        :run_with(tx):exec()
    if err then
        return nil, (errors.new({ message = "failed to delete component: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    -- Re-root each former direct child and its subtree.
    local child_rows = (children or {}) :: { { component_id: string, path: string? } }
    for _, child in ipairs(child_rows) do
        local rerr = reroot_subtree(tx, db, child.component_id, tostring(child.path))
        if rerr then
            return nil, rerr
        end
    end

    return {
        component_id = payload.component_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected,
        deleted = true,
    }, nil
end

-- Stamp the parent component's updated_at within the same tx.
local function touch_component(tx: Executor, component_id: string, now_ts: string): error?
    local _, err = sql.builder.update(consts.TABLES.COMPONENTS)
        :set("updated_at", now_ts)
        :where("component_id = ?", component_id)
        :run_with(tx):exec()
    if err then
        return (errors.new({ message = "failed to update component timestamp: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end
    return nil
end

-- PUT_META payload: { component_id, key, value }. Upsert by (component_id, key).
handlers[consts.COMMAND_TYPES.PUT_META] = function(tx: Executor, _db: Executor, command: Command): (CommandResult?, error?)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end
    if not payload.key or payload.key == "" then
        return nil, (errors.new({ message = "metadata key is required", kind = errors.INVALID }) :: error)
    end
    if payload.value == nil then
        return nil, (errors.new({ message = "metadata value is required", kind = errors.INVALID }) :: error)
    end

    local now_ts = time.now():format(time.RFC3339NANO)

    local result, err = sql.builder.update(consts.TABLES.META)
        :set("value", tostring(payload.value))
        :set("updated_at", now_ts)
        :where("component_id = ?", payload.component_id)
        :where("key = ?", payload.key)
        :run_with(tx):exec()
    if err then
        return nil, (errors.new({ message = "failed to update metadata: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    if result.rows_affected == 0 then
        local _, insert_err = sql.builder.insert(consts.TABLES.META)
            :set_map({
                meta_id = uuid.v7(),
                component_id = payload.component_id,
                key = payload.key,
                value = tostring(payload.value),
                created_at = now_ts,
                updated_at = now_ts,
            })
            :run_with(tx):exec()
        if insert_err then
            return nil, (errors.new({ message = "failed to insert metadata: " .. tostring(insert_err), kind = errors.INTERNAL }) :: error)
        end
    end

    local touch_err = touch_component(tx, payload.component_id :: string, now_ts)
    if touch_err then
        return nil, touch_err
    end

    return {
        component_id = payload.component_id,
        key = payload.key,
        value = payload.value,
        changes_made = true,
    }, nil
end

-- DELETE_META payload: { component_id, key }.
handlers[consts.COMMAND_TYPES.DELETE_META] = function(tx: Executor, _db: Executor, command: Command): (CommandResult?, error?)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end
    if not payload.key or payload.key == "" then
        return nil, (errors.new({ message = "metadata key is required", kind = errors.INVALID }) :: error)
    end

    local result, err = sql.builder.delete(consts.TABLES.META)
        :where("component_id = ?", payload.component_id)
        :where("key = ?", payload.key)
        :run_with(tx):exec()
    if err then
        return nil, (errors.new({ message = "failed to delete metadata: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    if result.rows_affected > 0 then
        local touch_err = touch_component(tx, payload.component_id :: string, time.now():format(time.RFC3339NANO))
        if touch_err then
            return nil, touch_err
        end
    end

    return {
        component_id = payload.component_id,
        key = payload.key,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected,
    }, nil
end

-- GRANT_ACCESS payload: { component_id, user_id, access_mask }. Upsert by
-- (component_id, user_id). user_id may be a user OR a group id.
handlers[consts.COMMAND_TYPES.GRANT_ACCESS] = function(tx: Executor, _db: Executor, command: Command): (CommandResult?, error?)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end
    if not payload.user_id or payload.user_id == "" then
        return nil, (errors.new({ message = "user ID is required", kind = errors.INVALID }) :: error)
    end
    if not payload.access_mask or payload.access_mask < 0 then
        return nil, (errors.new({ message = "valid access mask is required", kind = errors.INVALID }) :: error)
    end

    local now_ts = time.now():format(time.RFC3339NANO)

    local result, err = sql.builder.update(consts.TABLES.ACCESS)
        :set("access_mask", payload.access_mask)
        :where("component_id = ?", payload.component_id)
        :where("user_id = ?", payload.user_id)
        :run_with(tx):exec()
    if err then
        return nil, (errors.new({ message = "failed to update access: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    if result.rows_affected == 0 then
        local _, insert_err = sql.builder.insert(consts.TABLES.ACCESS)
            :set_map({
                access_id = uuid.v7(),
                user_id = payload.user_id,
                component_id = payload.component_id,
                access_mask = payload.access_mask,
                created_at = now_ts,
            })
            :run_with(tx):exec()
        if insert_err then
            return nil, (errors.new({ message = "failed to grant access: " .. tostring(insert_err), kind = errors.INTERNAL }) :: error)
        end
    end

    return {
        component_id = payload.component_id,
        user_id = payload.user_id,
        access_mask = payload.access_mask,
        changes_made = true,
    }, nil
end

-- REVOKE_ACCESS payload: { component_id, user_id }.
handlers[consts.COMMAND_TYPES.REVOKE_ACCESS] = function(tx: Executor, _db: Executor, command: Command): (CommandResult?, error?)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end
    if not payload.user_id or payload.user_id == "" then
        return nil, (errors.new({ message = "user ID is required", kind = errors.INVALID }) :: error)
    end

    local result, err = sql.builder.delete(consts.TABLES.ACCESS)
        :where("component_id = ?", payload.component_id)
        :where("user_id = ?", payload.user_id)
        :run_with(tx):exec()
    if err then
        return nil, (errors.new({ message = "failed to revoke access: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    return {
        component_id = payload.component_id,
        user_id = payload.user_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected,
    }, nil
end

-- SET_PLACEMENT payload: { component_id, has_parent_arg, parent_id?, position? }.
-- has_parent_arg true => apply parent_id (false/nil => root); false => keep
-- current parent. Re-parents and/or reorders, re-materializing the node's path
-- and every descendant's. Rejects cycles (moving a node under itself/its subtree).
handlers[consts.COMMAND_TYPES.SET_PLACEMENT] = function(tx: Executor, db: Executor, command: Command): (CommandResult?, error?)
    local payload = command.payload or {}

    if not payload.component_id or payload.component_id == "" then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end
    local component_id = payload.component_id :: string

    local node, nerr = placement.read_node(tx, component_id)
    if nerr then
        return nil, nerr
    end
    if not node then
        return nil, (errors.new({ message = "component not found", kind = errors.NOT_FOUND }) :: error)
    end

    -- Determine the target parent.
    local new_parent_id = node.parent_id
    if payload.has_parent_arg then
        local arg = payload.parent_id
        if arg == nil or arg == "" then
            new_parent_id = nil
        else
            new_parent_id = arg :: string
        end
    end

    local new_parent_path = nil
    if new_parent_id ~= nil then
        if new_parent_id == component_id then
            return nil, (errors.new({ message = "cannot place a component under itself", kind = errors.INVALID }) :: error)
        end
        -- Cycle guard: the new parent must not be inside this node's subtree.
        local inside, ierr = placement.is_self_or_descendant(tx, db, node.path, new_parent_id :: string)
        if ierr then
            return nil, ierr
        end
        if inside then
            return nil, (errors.new({ message = "cannot place a component under its own descendant", kind = errors.INVALID }) :: error)
        end

        local parent, perr = placement.read_node(tx, new_parent_id :: string)
        if perr then
            return nil, perr
        end
        if not parent then
            return nil, (errors.new({ message = "parent component not found", kind = errors.NOT_FOUND }) :: error)
        end
        new_parent_path = parent.path
    end

    -- Resolve target position: explicit, else append at end of new siblings.
    local new_position = payload.position
    if new_position == nil or new_position == "" then
        local last, lerr = placement.max_sibling_position(tx, new_parent_id)
        if lerr then
            return nil, lerr
        end
        new_position = placement.rank_between(last, nil)
    end

    -- Re-materialize the node's path, then rewrite every descendant relative to it.
    local old_path = node.path
    local new_path = placement.build_path(db, component_id, new_parent_path)
    local now_ts = time.now():format(time.RFC3339NANO)

    local _, uerr = sql.builder.update(consts.TABLES.COMPONENTS)
        :set("parent_id", new_parent_id)
        :set("position", new_position)
        :set("path", new_path)
        :set("updated_at", now_ts)
        :where("component_id = ?", component_id)
        :run_with(tx):exec()
    if uerr then
        return nil, (errors.new({ message = "failed to update placement: " .. tostring(uerr), kind = errors.INTERNAL }) :: error)
    end

    local descendants, derr = placement.descendants(tx, db, old_path)
    if derr then
        return nil, derr
    end

    for _, d in ipairs(descendants or {}) do
        -- Rewrite each descendant path by swapping the old subtree prefix for the
        -- new one (works for both ltree and sqlite materialized paths).
        local d_new = new_path .. tostring(d.path):sub(#tostring(old_path) + 1)
        local _, dperr = sql.builder.update(consts.TABLES.COMPONENTS)
            :set("path", d_new)
            :where("component_id = ?", d.component_id)
            :run_with(tx):exec()
        if dperr then
            return nil, (errors.new({ message = "failed to re-materialize descendant path: " .. tostring(dperr), kind = errors.INTERNAL }) :: error)
        end
    end

    return {
        component_id = component_id,
        parent_id = new_parent_id,
        position = new_position,
        path = new_path,
        changes_made = true,
    }, nil
end

-- Dispatch a command to its handler. Returns a NOT_FOUND error for an unknown
-- command type so callers never index a nil handler.
local function dispatch(tx: Executor, db: Executor, command: Command): (CommandResult?, error?)
    local handler = handlers[command.type]
    if not handler then
        return nil, (errors.new({ message = "no handler for command type: " .. tostring(command.type), kind = errors.NOT_FOUND }) :: error)
    end
    return handler(tx, db, command)
end

-- Check whether the user (or one of their groups) has the required access to a
-- component. access_subjects resolves the user into their subjects, so a grant
-- to any of the user's groups counts like a direct grant — same as the read path.
local function check_user_access(tx: Executor, user_id: string?, component_id: string?, required_mask: integer?): boolean
    if not user_id or not component_id or not required_mask then
        return false
    end

    local subjects = access_subjects.resolve(user_id)

    -- Authorized when one subject's grant on this component carries every required
    -- bit. The bitwise test runs in SQL for correctness on SQLite and PostgreSQL.
    local results, err = sql.builder.select("access_mask")
        :from(consts.TABLES.ACCESS)
        :where("user_id IN (" .. access_subjects.placeholders(subjects) .. ")", unpack(subjects))
        :where("component_id = ?", component_id)
        :where("(access_mask & ?) = ?", required_mask, required_mask)
        :limit(1)
        :run_with(tx):query()

    if err or not results or #results == 0 then
        return false
    end

    return true
end

-- Result of a subtree grant/revoke across a root and its descendants.
type SubtreeResult = {
    root_component_id: string,
    affected: integer,
    changes_made: boolean,
}

-- Apply a grant (or revoke) to a component subtree: the root plus every
-- descendant. revoke = true removes the subject's grant on each node instead.
local function apply_subtree_access(tx: Executor, db: Executor, root_component_id: string, subject: Subject, access_mask: integer, revoke: boolean): (SubtreeResult?, error?)
    local root, rerr = placement.read_node(tx, root_component_id)
    if rerr then
        return nil, rerr
    end
    if not root then
        return nil, (errors.new({ message = "root component not found", kind = errors.NOT_FOUND }) :: error)
    end

    local targets: { { component_id: string } } = { { component_id = root_component_id } }
    local descendants, derr = placement.descendants(tx, db, root.path)
    if derr then
        return nil, derr
    end
    for _, d in ipairs(descendants or {}) do
        targets[#targets + 1] = { component_id = d.component_id }
    end

    local affected = 0
    for _, t in ipairs(targets) do
        local cmd_type = revoke and consts.COMMAND_TYPES.REVOKE_ACCESS or consts.COMMAND_TYPES.GRANT_ACCESS
        local cmd_payload: { [string]: any } = { component_id = t.component_id, user_id = subject }
        if not revoke then
            cmd_payload.access_mask = access_mask
        end
        local res, herr = dispatch(tx, db, { type = cmd_type, payload = cmd_payload })
        if herr then
            return nil, herr
        end
        if res and res.changes_made then
            affected = affected + 1
        end
    end

    return { root_component_id = root_component_id, affected = affected, changes_made = affected > 0 }, nil
end

return {
    ACCESS = consts.ACCESS,
    COMMAND_TYPES = consts.COMMAND_TYPES,
    DB_RESOURCE = consts.DB_RESOURCE,
    DEFAULTS = consts.DEFAULTS,
    handlers = handlers,
    dispatch = dispatch,
    check_user_access = check_user_access,
    apply_subtree_access = apply_subtree_access,
}
