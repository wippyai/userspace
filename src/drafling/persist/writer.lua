local sql = require("sql")
local json = require("json")
local uuid = require("uuid")
local time = require("time")
local process = require("process")
local consts = require("drafling_consts")
local ops = require("ops")

local writer = {}

-- ============================================================================
-- FLUENT BATCH BUILDER
-- ============================================================================

local DraflingBatch = {}
DraflingBatch.__index = DraflingBatch

-- Create new batch instance
function DraflingBatch.new(user_id, project_id)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    local auto_generate_doc_id = not project_id
    if auto_generate_doc_id then
        project_id = uuid.v7()
    end

    return setmetatable({
        user_id = user_id,
        project_id = project_id,
        commands = {},
        auto_generate_doc_id = auto_generate_doc_id
    }, DraflingBatch), nil
end

-- ============================================================================
-- FLUENT COMMAND BUILDING METHODS
-- ============================================================================

function DraflingBatch:create_project(project_type, title, metadata)
    if not project_type then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_type"
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.CREATE_PROJECT,
        payload = {
            project_id = self.project_id,
            user_id = self.user_id,
            project_type = project_type,
            title = title,
            metadata = metadata
        }
    })
    return self, nil
end

function DraflingBatch:update_project(updates)
    if not self.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    local payload = { project_id = self.project_id }
    for k, v in pairs(updates or {}) do
        payload[k] = v
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.UPDATE_PROJECT,
        payload = payload
    })
    return self, nil
end

function DraflingBatch:delete_project()
    if not self.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.DELETE_PROJECT,
        payload = {
            project_id = self.project_id
        }
    })
    return self, nil
end

function DraflingBatch:create_category(name, display_name, metadata)
    if not self.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    if not name then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "name"
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.CREATE_CATEGORY,
        payload = {
            project_id = self.project_id,
            name = name,
            display_name = display_name,
            metadata = metadata
        }
    })
    return self, nil
end

function DraflingBatch:update_category(category_id, updates)
    if not category_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "category_id"
    end

    local payload = { category_id = category_id }
    for k, v in pairs(updates or {}) do
        payload[k] = v
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.UPDATE_CATEGORY,
        payload = payload
    })
    return self, nil
end

function DraflingBatch:delete_category(category_id)
    if not category_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "category_id"
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.DELETE_CATEGORY,
        payload = {
            category_id = category_id
        }
    })
    return self, nil
end

function DraflingBatch:create_entry(category_id, entry_type, content, content_type, title, status, metadata)
    if not self.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    if not category_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "category_id"
    end

    if not entry_type then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "type"
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.CREATE_ENTRY,
        payload = {
            project_id = self.project_id,
            category_id = category_id,
            type = entry_type,
            content = content,
            content_type = content_type or consts.DEFAULTS.ENTRY_CONTENT_TYPE,
            title = title,
            status = status or consts.DEFAULTS.ENTRY_STATUS,
            metadata = metadata
        }
    })
    return self, nil
end

function DraflingBatch:update_entry(entry_id, updates)
    if not entry_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "entry_id"
    end

    local payload = { entry_id = entry_id }
    for k, v in pairs(updates or {}) do
        payload[k] = v
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.UPDATE_ENTRY,
        payload = payload
    })
    return self, nil
end

function DraflingBatch:delete_entry(entry_id)
    if not entry_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "entry_id"
    end

    table.insert(self.commands, {
        type = consts.OPERATION_TYPE.DELETE_ENTRY,
        payload = {
            entry_id = entry_id
        }
    })
    return self, nil
end

-- ============================================================================
-- EXECUTION METHODS
-- ============================================================================

function DraflingBatch:execute(options)
    if #self.commands == 0 then
        return { commands = {}, changes_made = false }, nil
    end

    if not self.project_id then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    return writer.execute(self.user_id, self.project_id, self.commands, options)
end

-- ============================================================================
-- PRIVATE HELPERS
-- ============================================================================

-- Helper function to get database connection
local function get_db()
    local db, err = sql.get(consts.APP_DB)
    if err then
        return nil, consts.ERROR.DB_CONNECTION_FAILED .. ": " .. err
    end
    return db, nil
end

-- Isolated method for sending process messages (can be mocked in tests)
function writer._send_process_message(target_process, topic, payload)
    if not process or not process.send then
        return
    end
    process.send(target_process, topic, payload)
end

-- Isolated method for getting current timestamp (can be mocked in tests)
function writer._get_current_timestamp()
    return time.now():format(time.RFC3339NANO)
end

-- ============================================================================
-- REAL-TIME PUBLISHING
-- ============================================================================

-- Function to publish updates about project changes
-- Send updates to the user process with topic "user.{user_id}.project.{project_id}"
function writer.publish_updates(user_id, project_id, result)
    if not result or not result.changes_made or not result.results then
        return
    end

    local user_process = "user." .. user_id
    local topic = consts.TOPIC.PROJECT_PREFIX .. project_id
    local now_ts = writer._get_current_timestamp()

    -- Process all operations and send specific events
    for _, cmd_result in ipairs(result.results) do
        if not (cmd_result and cmd_result.changes_made and cmd_result.input) then
            goto continue
        end

        local cmd_type = cmd_result.input.type
        local payload = cmd_result.input.payload or {}

        -- Document operations
        if cmd_type == consts.OPERATION_TYPE.CREATE_PROJECT then
            writer._send_process_message(user_process, topic, {
                event_type = "project_created",
                project_id = project_id,
                project_type = payload.project_type,
                title = payload.title,
                status = payload.status,
                updated_at = now_ts
            })
        elseif cmd_type == consts.OPERATION_TYPE.UPDATE_PROJECT then
            writer._send_process_message(user_process, topic, {
                event_type = "project_updated",
                project_id = project_id,
                updated_fields = {
                    title = payload.title,
                    status = payload.status,
                    metadata = payload.metadata
                },
                updated_at = now_ts
            })
        elseif cmd_type == consts.OPERATION_TYPE.DELETE_PROJECT then
            writer._send_process_message(user_process, topic, {
                event_type = "project_deleted",
                project_id = project_id,
                updated_at = now_ts
            })

            -- Category operations
        elseif cmd_type == consts.OPERATION_TYPE.CREATE_CATEGORY then
            writer._send_process_message(user_process, topic, {
                event_type = "category_created",
                project_id = project_id,
                category_id = cmd_result.category_id,
                name = payload.name,
                display_name = payload.display_name,
                updated_at = now_ts
            })
        elseif cmd_type == consts.OPERATION_TYPE.UPDATE_CATEGORY then
            writer._send_process_message(user_process, topic, {
                event_type = "category_updated",
                project_id = project_id,
                category_id = payload.category_id,
                updated_fields = {
                    display_name = payload.display_name,
                    metadata = payload.metadata
                },
                updated_at = now_ts
            })
        elseif cmd_type == consts.OPERATION_TYPE.DELETE_CATEGORY then
            writer._send_process_message(user_process, topic, {
                event_type = "category_deleted",
                project_id = project_id,
                category_id = payload.category_id,
                updated_at = now_ts
            })

            -- Entry operations
        elseif cmd_type == consts.OPERATION_TYPE.CREATE_ENTRY then
            writer._send_process_message(user_process, topic, {
                event_type = "entry_created",
                project_id = project_id,
                entry_id = cmd_result.entry_id,
                category_id = payload.category_id,
                type = payload.type,
                content_type = payload.content_type,
                title = payload.title,
                status = payload.status,
                updated_at = now_ts
            })
        elseif cmd_type == consts.OPERATION_TYPE.UPDATE_ENTRY then
            writer._send_process_message(user_process, topic, {
                event_type = "entry_updated",
                project_id = project_id,
                entry_id = payload.entry_id,
                updated_fields = {
                    type = payload.type,
                    content = payload.content,
                    content_type = payload.content_type,
                    title = payload.title,
                    status = payload.status,
                    metadata = payload.metadata
                },
                updated_at = now_ts
            })
        elseif cmd_type == consts.OPERATION_TYPE.DELETE_ENTRY then
            writer._send_process_message(user_process, topic, {
                event_type = "entry_deleted",
                project_id = project_id,
                entry_id = payload.entry_id,
                updated_at = now_ts
            })
        end

        ::continue::
    end
end

-- ============================================================================
-- TRANSACTION MANAGEMENT
-- ============================================================================

-- Execute commands within a provided transaction
function writer.tx_execute(tx, user_id, project_id, commands, options)
    if not tx then
        return nil, consts.ERROR.TRANSACTION_REQUIRED
    end

    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    if not project_id or project_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    if not commands or type(commands) ~= "table" or #commands == 0 then
        return nil, consts.ERROR.COMMANDS_EMPTY
    end

    options = options or {}

    -- Execute the operations within the provided transaction
    local result, err = ops.execute(tx, commands)
    if err then
        return nil, err
    end

    -- Handle publishing if enabled (default is true)
    if options.publish ~= false then
        writer.publish_updates(user_id, project_id, result)
    end

    return result, nil
end

-- Execute commands directly
function writer.execute(user_id, project_id, commands, options)
    if not user_id or user_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "user_id"
    end

    if not project_id or project_id == "" then
        return nil, consts.ERROR.MISSING_REQUIRED_FIELD .. "project_id"
    end

    if not commands then
        return nil, consts.ERROR.COMMANDS_REQUIRED
    end

    -- Ensure commands is always an array
    if type(commands) ~= "table" then
        return nil, consts.ERROR.COMMANDS_REQUIRED
    end

    -- Check if commands is empty
    if #commands == 0 then
        return nil, consts.ERROR.COMMANDS_EMPTY
    end

    options = options or {}

    -- Get database connection
    local db, err_db = get_db()
    if err_db then
        return nil, err_db
    end

    -- Begin transaction
    local tx, err_tx = db:begin()
    if err_tx then
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err_tx
    end

    -- Execute the operations
    local result, err_op = writer.tx_execute(tx, user_id, project_id, commands, { publish = false })

    -- Handle errors
    if err_op then
        tx:rollback()
        db:release()
        return nil, err_op
    end

    -- Commit the transaction
    local success, err_commit = tx:commit()
    if err_commit then
        tx:rollback()
        db:release()
        return nil, consts.ERROR.DB_OPERATION_FAILED .. ": " .. err_commit
    end

    -- Release the connection
    db:release()

    -- Handle publishing if enabled (default is true)
    if options.publish ~= false then
        writer.publish_updates(user_id, project_id, result)
    end

    -- Return the result
    return result, nil
end

-- ============================================================================
-- MAIN MODULE INTERFACE
-- ============================================================================

-- Start a fluent batch for a user (auto-generates project ID)
function writer.for_user(user_id)
    return DraflingBatch.new(user_id, nil)
end

-- Start a fluent batch for a specific project
function writer.for_project(user_id, project_id)
    return DraflingBatch.new(user_id, project_id)
end

return writer
