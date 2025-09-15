local sql = require("sql")
local time = require("time")
local uuid = require("uuid")
local json = require("json")

-- Define constants
local constants = {
    -- Access mask constants (bitmask permissions)
    ACCESS = {
        NONE = 0,   -- 0000 - No access
        READ = 1,   -- 0001 - Can read component metadata
        WRITE = 2,  -- 0010 - Can modify component metadata
        DELETE = 4, -- 0100 - Can delete component
        ADMIN = 8,  -- 1000 - Full admin access (grant/revoke permissions)

        -- Common combinations
        READ_WRITE = 3,   -- 0011 - Read and write
        READ_DELETE = 5,  -- 0101 - Read and delete
        WRITE_DELETE = 6, -- 0110 - Write and delete
        FULL = 15,        -- 1111 - All permissions
    },

    -- Command types for component operations
    COMMAND_TYPES = {
        -- Component operations (immutable - create or delete only)
        CREATE_COMPONENT = "CREATE_COMPONENT",
        DELETE_COMPONENT = "DELETE_COMPONENT",

        -- Metadata operations (only mutable part)
        PUT_META = "PUT_META",       -- Set/update metadata key-value pair
        DELETE_META = "DELETE_META", -- Remove metadata key

        -- Access control operations
        GRANT_ACCESS = "GRANT_ACCESS",   -- Grant access to user
        REVOKE_ACCESS = "REVOKE_ACCESS", -- Remove access from user
    },

    -- Database constants
    DB_RESOURCE = "app:db",

    -- Default values
    DEFAULTS = {
        ACCESS_MASK = 15, -- FULL access for component creator
        ORDER_BY = "created_at",
        ORDER_DIRECTION = "DESC",
        LIMIT = 50,
    }
}

-- Define command handlers for component operations
local handlers = {}

-- Component Operations

-- Structure:
-- {
--   type = ops.COMMAND_TYPES.CREATE_COMPONENT,
--   payload = {
--     component_id = "uuid", -- optional, generated if not provided
--     impl_id = "namespace:implementation", -- required
--     private_context = { ... }, -- optional, table or JSON string
--     initial_meta = { ... }, -- optional, initial metadata
--     owner_user_id = "user_id" -- required, who owns this component
--   }
-- }
handlers[constants.COMMAND_TYPES.CREATE_COMPONENT] = function(tx, command)
    local payload = command.payload or {}

    if not payload.impl_id or payload.impl_id == "" then
        return nil, "Implementation ID is required"
    end

    if not payload.owner_user_id or payload.owner_user_id == "" then
        return nil, "Owner user ID is required"
    end

    -- Generate component ID if not provided
    local component_id = payload.component_id or uuid.v7()

    -- Handle private context
    local private_context = payload.private_context or {}
    if type(private_context) == "table" then
        local encoded, err_encode = json.encode(private_context)
        if err_encode then
            return nil, "Failed to encode private context: " .. err_encode
        end
        private_context = encoded
    end

    local now_ts = time.now():format(time.RFC3339NANO)

    -- Create the component
    local insert_query = sql.builder.insert("components")
        :set_map({
            component_id = component_id,
            impl_id = payload.impl_id,
            private_context = private_context,
            created_at = now_ts,
            updated_at = now_ts
        })

    local executor = insert_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to create component: " .. err
    end

    -- Grant full access to the owner
    local access_query = sql.builder.insert("component_access")
        :set_map({
            access_id = uuid.v7(),
            user_id = payload.owner_user_id,
            component_id = component_id,
            access_mask = constants.ACCESS.FULL,
            created_at = now_ts
        })

    executor = access_query:run_with(tx)
    result, err = executor:exec()

    if err then
        return nil, "Failed to create component access: " .. err
    end

    -- Add initial metadata if provided
    if payload.initial_meta and type(payload.initial_meta) == "table" then
        for key, value in pairs(payload.initial_meta) do
            local meta_query = sql.builder.insert("component_meta")
                :set_map({
                    meta_id = uuid.v7(),
                    component_id = component_id,
                    key = key,
                    value = tostring(value),
                    created_at = now_ts,
                    updated_at = now_ts
                })

            executor = meta_query:run_with(tx)
            local meta_result, meta_err = executor:exec()

            if meta_err then
                return nil, "Failed to create initial metadata: " .. meta_err
            end
        end
    end

    return {
        component_id = component_id,
        changes_made = true
    }
end

-- Structure:
-- {
--   type = ops.COMMAND_TYPES.DELETE_COMPONENT,
--   payload = {
--     component_id = "uuid" -- required
--   }
-- }
handlers[constants.COMMAND_TYPES.DELETE_COMPONENT] = function(tx, command)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, "Component ID is required"
    end

    -- Delete component (cascades to meta and access tables)
    local delete_query = sql.builder.delete("components")
        :where("component_id = ?", payload.component_id)

    local executor = delete_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to delete component: " .. err
    end

    return {
        component_id = payload.component_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected,
        deleted = true
    }
end

-- Metadata Operations

-- Structure:
-- {
--   type = ops.COMMAND_TYPES.PUT_META,
--   payload = {
--     component_id = "uuid", -- required
--     key = "meta_key", -- required
--     value = "meta_value" -- required
--   }
-- }
handlers[constants.COMMAND_TYPES.PUT_META] = function(tx, command)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, "Component ID is required"
    end

    if not payload.key or payload.key == "" then
        return nil, "Metadata key is required"
    end

    if payload.value == nil then
        return nil, "Metadata value is required"
    end

    local now_ts = time.now():format(time.RFC3339NANO)

    -- Try to update existing metadata entry
    local update_query = sql.builder.update("component_meta")
        :set("value", tostring(payload.value))
        :set("updated_at", now_ts)
        :where("component_id = ?", payload.component_id)
        :where("key = ?", payload.key)

    local executor = update_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to update metadata: " .. err
    end

    -- If no rows were updated, insert new metadata entry
    if result.rows_affected == 0 then
        local insert_query = sql.builder.insert("component_meta")
            :set_map({
                meta_id = uuid.v7(),
                component_id = payload.component_id,
                key = payload.key,
                value = tostring(payload.value),
                created_at = now_ts,
                updated_at = now_ts
            })

        executor = insert_query:run_with(tx)
        result, err = executor:exec()

        if err then
            return nil, "Failed to insert metadata: " .. err
        end
    end

    -- Update component timestamp
    local comp_update = sql.builder.update("components")
        :set("updated_at", now_ts)
        :where("component_id = ?", payload.component_id)

    executor = comp_update:run_with(tx)
    local comp_result, comp_err = executor:exec()

    if comp_err then
        return nil, "Failed to update component timestamp: " .. comp_err
    end

    return {
        component_id = payload.component_id,
        key = payload.key,
        value = payload.value,
        changes_made = true
    }
end

-- Structure:
-- {
--   type = ops.COMMAND_TYPES.DELETE_META,
--   payload = {
--     component_id = "uuid", -- required
--     key = "meta_key" -- required
--   }
-- }
handlers[constants.COMMAND_TYPES.DELETE_META] = function(tx, command)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, "Component ID is required"
    end

    if not payload.key or payload.key == "" then
        return nil, "Metadata key is required"
    end

    local delete_query = sql.builder.delete("component_meta")
        :where("component_id = ?", payload.component_id)
        :where("key = ?", payload.key)

    local executor = delete_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to delete metadata: " .. err
    end

    -- Update component timestamp if metadata was deleted
    if result.rows_affected > 0 then
        local comp_update = sql.builder.update("components")
            :set("updated_at", time.now():format(time.RFC3339NANO))
            :where("component_id = ?", payload.component_id)

        executor = comp_update:run_with(tx)
        local comp_result, comp_err = executor:exec()

        if comp_err then
            return nil, "Failed to update component timestamp: " .. comp_err
        end
    end

    return {
        component_id = payload.component_id,
        key = payload.key,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected
    }
end

-- Access Control Operations

-- Structure:
-- {
--   type = ops.COMMAND_TYPES.GRANT_ACCESS,
--   payload = {
--     component_id = "uuid", -- required
--     user_id = "user_id", -- required
--     access_mask = 3 -- required, bitmask of permissions
--   }
-- }
handlers[constants.COMMAND_TYPES.GRANT_ACCESS] = function(tx, command)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, "Component ID is required"
    end

    if not payload.user_id or payload.user_id == "" then
        return nil, "User ID is required"
    end

    if not payload.access_mask or payload.access_mask < 0 then
        return nil, "Valid access mask is required"
    end

    local now_ts = time.now():format(time.RFC3339NANO)

    -- Try to update existing access entry
    local update_query = sql.builder.update("component_access")
        :set("access_mask", payload.access_mask)
        :where("component_id = ?", payload.component_id)
        :where("user_id = ?", payload.user_id)

    local executor = update_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to update access: " .. err
    end

    -- If no rows were updated, insert new access entry
    if result.rows_affected == 0 then
        local insert_query = sql.builder.insert("component_access")
            :set_map({
                access_id = uuid.v7(),
                user_id = payload.user_id,
                component_id = payload.component_id,
                access_mask = payload.access_mask,
                created_at = now_ts
            })

        executor = insert_query:run_with(tx)
        result, err = executor:exec()

        if err then
            return nil, "Failed to grant access: " .. err
        end
    end

    return {
        component_id = payload.component_id,
        user_id = payload.user_id,
        access_mask = payload.access_mask,
        changes_made = true
    }
end

-- Structure:
-- {
--   type = ops.COMMAND_TYPES.REVOKE_ACCESS,
--   payload = {
--     component_id = "uuid", -- required
--     user_id = "user_id" -- required
--   }
-- }
handlers[constants.COMMAND_TYPES.REVOKE_ACCESS] = function(tx, command)
    local payload = command.payload or {}

    if not payload.component_id then
        return nil, "Component ID is required"
    end

    if not payload.user_id or payload.user_id == "" then
        return nil, "User ID is required"
    end

    local delete_query = sql.builder.delete("component_access")
        :where("component_id = ?", payload.component_id)
        :where("user_id = ?", payload.user_id)

    local executor = delete_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, "Failed to revoke access: " .. err
    end

    return {
        component_id = payload.component_id,
        user_id = payload.user_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected
    }
end

-- Helper function to check if user has specific access to component
local function check_user_access(tx, user_id, component_id, required_mask)
    if not user_id or not component_id or not required_mask then
        return false
    end

    local access_query = sql.builder.select("access_mask")
        :from("component_access")
        :where("user_id = ?", user_id)
        :where("component_id = ?", component_id)
        :limit(1)

    local executor = access_query:run_with(tx)
    local results, err = executor:query()

    if err or not results or #results == 0 then
        return false
    end

    local user_mask = results[1].access_mask or 0
    return (user_mask and required_mask) == required_mask
end

-- Return the module
local module = {
    ACCESS = constants.ACCESS,
    COMMAND_TYPES = constants.COMMAND_TYPES,
    DB_RESOURCE = constants.DB_RESOURCE,
    DEFAULTS = constants.DEFAULTS,
    handlers = handlers,
    check_user_access = check_user_access
}

return module
