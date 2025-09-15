local sql = require("sql")
local json = require("json")
local time = require("time")
local uuid = require("uuid")
local consts = require("drafling_consts")

local ops = {}

-- Export operation constants
ops.OPERATION_TYPE = consts.OPERATION_TYPE
ops.HISTORY_OPERATION = consts.HISTORY_OPERATION

-- ============================================================================
-- PRIVATE HELPERS
-- ============================================================================

-- Validation helper functions
local function validate_status(status)
    -- we really dont care at this level
    return true
end

local function validate_content_type(content_type)
    if not content_type then return true end -- Allow null, will use default
    return consts.VALID_VALUES.CONTENT_TYPE[content_type] ~= nil
end

-- Helper to encode metadata
local function encode_metadata(metadata)
    if not metadata then
        return consts.DEFAULTS.METADATA
    end

    if type(metadata) == "string" then
        return metadata
    end

    if type(metadata) == "table" then
        local encoded, err = json.encode(metadata)
        if err then
            return nil, consts.ERROR.JSON_ENCODE_FAILED .. ": " .. err
        end
        return encoded
    end

    return consts.DEFAULTS.METADATA
end

-- Helper to create history record
local function create_history(tx, entry_id, project_id, operation_type, changes)
    if not entry_id or not project_id or not operation_type then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "entry_id, project_id, or operation_type"
    end

    if not consts.VALID_VALUES.HISTORY_OPERATION[operation_type] then
        return nil, consts.ERROR.INVALID_FIELD_VALUE .. "operation_type"
    end

    local history_id = uuid.v7()
    local now_ts = time.now():format(time.RFC3339NANO)

    local changes_json, encode_err = encode_metadata(changes)
    if encode_err then
        return nil, consts.ERROR.HISTORY_CREATE_FAILED .. ": " .. encode_err
    end

    local insert_query = sql.builder.insert("drafling_entry_history")
        :set_map({
            history_id = history_id,
            entry_id = entry_id,
            project_id = project_id,
            operation_type = operation_type,
            changes = changes_json,
            created_at = now_ts
        })

    local executor = insert_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.HISTORY_CREATE_FAILED .. ": " .. err
    end

    return history_id
end

-- ============================================================================
-- COMMAND HANDLERS
-- ============================================================================

local handlers = {}

-- Document Operations
handlers[consts.OPERATION_TYPE.CREATE_PROJECT] = function(tx, command)
    local payload = command.payload or {}

    if not payload.user_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    if not payload.project_type then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_type"
    end

    -- Validate status if provided
    if payload.status and not validate_status(payload.status) then
        return nil, consts.ERROR.INVALID_STATUS
    end

    local project_id = payload.project_id or uuid.v7()
    local now_ts = time.now():format(time.RFC3339NANO)

    local metadata, metadata_err = encode_metadata(payload.metadata)
    if metadata_err then
        return nil, metadata_err
    end

    local insert_query = sql.builder.insert("drafling_projects")
        :set_map({
            project_id = project_id,
            user_id = payload.user_id,
            project_type = payload.project_type,
            title = payload.title,
            status = payload.status or consts.DEFAULTS.PROJECT_STATUS,
            metadata = metadata,
            created_at = now_ts,
            updated_at = now_ts
        })

    local executor = insert_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        project_id = project_id,
        changes_made = true
    }
end

handlers[consts.OPERATION_TYPE.UPDATE_PROJECT] = function(tx, command)
    local payload = command.payload or {}

    if not payload.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    -- Validate status if provided
    if payload.status and not validate_status(payload.status) then
        return nil, consts.ERROR.INVALID_STATUS
    end

    local update_query = sql.builder.update("drafling_projects")
        :where("project_id = ?", payload.project_id)

    local has_update = false

    if payload.title then
        update_query = update_query:set(consts.UPDATE_FIELD_TYPE.PROJECT_TITLE, payload.title)
        has_update = true
    end

    if payload.status then
        update_query = update_query:set(consts.UPDATE_FIELD_TYPE.PROJECT_STATUS, payload.status)
        has_update = true
    end

    if payload.metadata then
        local metadata, metadata_err = encode_metadata(payload.metadata)
        if metadata_err then
            return nil, metadata_err
        end
        update_query = update_query:set(consts.UPDATE_FIELD_TYPE.PROJECT_METADATA, metadata)
        has_update = true
    end

    if not has_update then
        return {
            project_id = payload.project_id,
            changes_made = false,
            message = consts.ERROR.NO_FIELDS_TO_UPDATE
        }
    end

    local now_ts = time.now():format(time.RFC3339NANO)
    update_query = update_query:set("updated_at", now_ts)

    local executor = update_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        project_id = payload.project_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected
    }
end

handlers[consts.OPERATION_TYPE.DELETE_PROJECT] = function(tx, command)
    local payload = command.payload or {}

    if not payload.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    local delete_query = sql.builder.delete("drafling_projects")
        :where("project_id = ?", payload.project_id)

    local executor = delete_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        project_id = payload.project_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected,
        deleted = true
    }
end

-- Category Operations
handlers[consts.OPERATION_TYPE.CREATE_CATEGORY] = function(tx, command)
    local payload = command.payload or {}

    if not payload.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    if not payload.name then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "name"
    end

    local category_id = payload.category_id or uuid.v7()
    local now_ts = time.now():format(time.RFC3339NANO)

    local metadata, metadata_err = encode_metadata(payload.metadata)
    if metadata_err then
        return nil, metadata_err
    end

    local insert_query = sql.builder.insert("drafling_categories")
        :set_map({
            category_id = category_id,
            project_id = payload.project_id,
            name = payload.name,
            display_name = payload.display_name,
            metadata = metadata,
            created_at = now_ts
        })

    local executor = insert_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        category_id = category_id,
        changes_made = true
    }
end

handlers[consts.OPERATION_TYPE.UPDATE_CATEGORY] = function(tx, command)
    local payload = command.payload or {}

    if not payload.category_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "category_id"
    end

    local update_query = sql.builder.update("drafling_categories")
        :where("category_id = ?", payload.category_id)

    local has_update = false

    if payload.display_name then
        update_query = update_query:set(consts.UPDATE_FIELD_TYPE.CATEGORY_DISPLAY_NAME, payload.display_name)
        has_update = true
    end

    if payload.metadata then
        local metadata, metadata_err = encode_metadata(payload.metadata)
        if metadata_err then
            return nil, metadata_err
        end
        update_query = update_query:set(consts.UPDATE_FIELD_TYPE.CATEGORY_METADATA, metadata)
        has_update = true
    end

    if not has_update then
        return {
            category_id = payload.category_id,
            changes_made = false,
            message = consts.ERROR.NO_FIELDS_TO_UPDATE
        }
    end

    local executor = update_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        category_id = payload.category_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected
    }
end

handlers[consts.OPERATION_TYPE.DELETE_CATEGORY] = function(tx, command)
    local payload = command.payload or {}

    if not payload.category_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "category_id"
    end

    local delete_query = sql.builder.delete("drafling_categories")
        :where("category_id = ?", payload.category_id)

    local executor = delete_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    return {
        category_id = payload.category_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected,
        deleted = true
    }
end

-- Entry Operations
handlers[consts.OPERATION_TYPE.CREATE_ENTRY] = function(tx, command)
    local payload = command.payload or {}

    if not payload.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    if not payload.category_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "category_id"
    end

    if not payload.type then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "type"
    end

    -- Validate fields if provided
    if payload.status and not validate_status(payload.status) then
        return nil, consts.ERROR.INVALID_STATUS
    end

    if payload.content_type and not validate_content_type(payload.content_type) then
        return nil, consts.ERROR.INVALID_CONTENT_TYPE
    end

    -- Validate that the category exists and belongs to the project
    local category_check = sql.builder.select("category_id")
        :from("drafling_categories")
        :where("category_id = ? AND project_id = ?", payload.category_id, payload.project_id)
        :limit(1)

    local check_executor = category_check:run_with(tx)
    local check_result, check_err = check_executor:query()

    if check_err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. check_err
    end

    if not check_result or #check_result == 0 then
        return nil, consts.ERROR.CATEGORY_PROJECT_MISMATCH
    end

    local entry_id = payload.entry_id or uuid.v7()
    local now_ts = time.now():format(time.RFC3339NANO)

    local metadata, metadata_err = encode_metadata(payload.metadata)
    if metadata_err then
        return nil, metadata_err
    end

    local insert_query = sql.builder.insert("drafling_entries")
        :set_map({
            entry_id = entry_id,
            project_id = payload.project_id,
            category_id = payload.category_id,
            type = payload.type,
            content = payload.content,
            content_type = payload.content_type or consts.DEFAULTS.ENTRY_CONTENT_TYPE,
            title = payload.title,
            status = payload.status or consts.DEFAULTS.ENTRY_STATUS,
            metadata = metadata,
            created_at = now_ts,
            updated_at = now_ts
        })

    local executor = insert_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    -- Create history record using standardized structure
    local changes = {
        [consts.HISTORY_CHANGE.OPERATION] = consts.HISTORY_CHANGE.OP_CREATE,
        [consts.HISTORY_CHANGE.INITIAL_VALUES] = {
            type = payload.type,
            content = payload.content,
            content_type = payload.content_type or consts.DEFAULTS.ENTRY_CONTENT_TYPE,
            title = payload.title,
            status = payload.status or consts.DEFAULTS.ENTRY_STATUS
        }
    }

    local history_id, history_err = create_history(tx, entry_id, payload.project_id, consts.HISTORY_OPERATION.CREATE,
        changes)
    if history_err then
        return nil, history_err
    end

    return {
        entry_id = entry_id,
        changes_made = true,
        history_id = history_id
    }
end

handlers[consts.OPERATION_TYPE.UPDATE_ENTRY] = function(tx, command)
    local payload = command.payload or {}

    if not payload.entry_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "entry_id"
    end

    -- Validate fields if provided
    if payload.status and not validate_status(payload.status) then
        return nil, consts.ERROR.INVALID_STATUS
    end

    if payload.content_type and not validate_content_type(payload.content_type) then
        return nil, consts.ERROR.INVALID_CONTENT_TYPE
    end

    -- Get current values for history
    local current_query = sql.builder.select("project_id", "type", "content", "content_type", "title", "status",
            "metadata")
        :from("drafling_entries")
        :where("entry_id = ?", payload.entry_id)
        :limit(1)

    local current_executor = current_query:run_with(tx)
    local current_result, current_err = current_executor:query()

    if current_err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. current_err
    end

    if #current_result == 0 then
        return nil, consts.ERROR.ENTRY_NOT_FOUND
    end

    local current = current_result[1]

    local update_query = sql.builder.update("drafling_entries")
        :where("entry_id = ?", payload.entry_id)

    local has_update = false
    local changes = {
        [consts.HISTORY_CHANGE.FIELDS_CHANGED] = {},
        [consts.HISTORY_CHANGE.FROM] = {},
        [consts.HISTORY_CHANGE.TO] = {}
    }

    -- Check each trackable field for changes
    for _, field in ipairs(consts.TRACKABLE_FIELDS.ENTRY) do
        local new_value = payload[field]
        local current_value = current[field]

        if new_value ~= nil and new_value ~= current_value then
            if field == consts.UPDATE_FIELD_TYPE.ENTRY_METADATA then
                local metadata, metadata_err = encode_metadata(new_value)
                if metadata_err then
                    return nil, metadata_err
                end
                new_value = metadata
            end

            update_query = update_query:set(field, new_value)
            table.insert(changes[consts.HISTORY_CHANGE.FIELDS_CHANGED], field)
            changes[consts.HISTORY_CHANGE.FROM][field] = current_value
            changes[consts.HISTORY_CHANGE.TO][field] = new_value
            has_update = true
        end
    end

    if not has_update then
        return {
            entry_id = payload.entry_id,
            changes_made = false,
            message = consts.ERROR.NO_FIELDS_TO_UPDATE
        }
    end

    local now_ts = time.now():format(time.RFC3339NANO)
    update_query = update_query:set("updated_at", now_ts)

    local executor = update_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    -- Create history record
    local history_id, history_err = create_history(tx, payload.entry_id, current.project_id,
        consts.HISTORY_OPERATION.UPDATE, changes)
    if history_err then
        return nil, history_err
    end

    return {
        entry_id = payload.entry_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected,
        history_id = history_id
    }
end

handlers[consts.OPERATION_TYPE.DELETE_ENTRY] = function(tx, command)
    local payload = command.payload or {}

    if not payload.entry_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "entry_id"
    end

    -- Get current values for history
    local current_query = sql.builder.select("project_id", "type", "content", "content_type", "title", "status")
        :from("drafling_entries")
        :where("entry_id = ?", payload.entry_id)
        :limit(1)

    local current_executor = current_query:run_with(tx)
    local current_result, current_err = current_executor:query()

    if current_err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. current_err
    end

    if #current_result == 0 then
        return nil, consts.ERROR.ENTRY_NOT_FOUND
    end

    local current = current_result[1]

    local delete_query = sql.builder.delete("drafling_entries")
        :where("entry_id = ?", payload.entry_id)

    local executor = delete_query:run_with(tx)
    local result, err = executor:exec()

    if err then
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err
    end

    -- Create history record using standardized structure
    local changes = {
        [consts.HISTORY_CHANGE.OPERATION] = consts.HISTORY_CHANGE.OP_DELETE,
        [consts.HISTORY_CHANGE.DELETED_VALUES] = {
            type = current.type,
            content = current.content,
            content_type = current.content_type,
            title = current.title,
            status = current.status
        }
    }

    local history_id, history_err = create_history(tx, payload.entry_id, current.project_id,
        consts.HISTORY_OPERATION.DELETE, changes)
    if history_err then
        return nil, history_err
    end

    return {
        entry_id = payload.entry_id,
        changes_made = result.rows_affected > 0,
        rows_affected = result.rows_affected,
        deleted = true,
        history_id = history_id
    }
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- Execute commands within a transaction
function ops.execute(tx, commands)
    if not tx then
        return nil, consts.ERROR.TRANSACTION_REQUIRED
    end

    if not commands or type(commands) ~= "table" then
        return nil, consts.ERROR.COMMANDS_REQUIRED
    end

    -- Handle both single command and array of commands
    local command_array = {}
    if commands.type then
        -- Single command
        table.insert(command_array, commands)
    else
        -- Array of commands
        command_array = commands
    end

    if #command_array == 0 then
        return nil, consts.ERROR.COMMANDS_EMPTY
    end

    local changes_made = false
    local results = {}

    for i, command in ipairs(command_array) do
        local handler = handlers[command.type]

        if not handler then
            return nil, consts.ERROR.UNKNOWN_COMMAND_TYPE .. (command.type or "nil") .. " at index " .. i
        end

        local result, err = handler(tx, command)

        if err then
            return nil, "Error executing command at index " .. i .. ": " .. err
        end

        if result and result.changes_made then
            changes_made = true
            result.input = command
        end

        table.insert(results, result)
    end

    return {
        results = results,
        changes_made = changes_made
    }, nil
end

return ops
