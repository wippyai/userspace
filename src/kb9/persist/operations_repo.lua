local sql = require("sql")
local time = require("time")
local uuid = require("uuid")
local consts = require("userspace_consts")

local operations_repo = {}

local function get_db()
    local db, err = sql.get("app:db")
    if err then
        return nil, "DB connection failed: " .. err
    end
    return db
end

function operations_repo.create(data)
    if not data.id or data.id == "" then
        return nil, "id is required"
    end

    if not data.component_id or data.component_id == "" then
        return nil, "component_id is required"
    end

    if not data.upload_uuid or data.upload_uuid == "" then
        return nil, "upload_uuid is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local now = time.now()
    local status = data.status or consts.OPERATION_STATUS.PROCESSING

    local query = sql.builder.insert("kb_embed_operations")
        :set_map({
            id = data.id,
            component_id = data.component_id,
            upload_uuid = data.upload_uuid,
            status = status,
            error = data.error,
            ops_executed = data.ops_executed or 0,
            created_at = db:type() == sql.type.SQLITE and now:unix() or now:format(time.RFC3339),
            updated_at = db:type() == sql.type.SQLITE and now:unix() or now:format(time.RFC3339)
        })

    local executor = query:run_with(db)
    local result, exec_err = executor:exec()

    db:release()

    if exec_err then
        return nil, "Failed to create operation: " .. exec_err
    end

    return {
        id = data.id,
        component_id = data.component_id,
        upload_uuid = data.upload_uuid,
        status = status,
        created = true
    }
end

function operations_repo.get(id)
    if not id or id == "" then
        return nil, "id is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("id", "component_id", "upload_uuid", "status", "error", "ops_executed", "created_at", "updated_at")
        :from("kb_embed_operations")
        :where("id = ?", id)
        :limit(1)

    local executor = query:run_with(db)
    local rows, exec_err = executor:query()

    db:release()

    if exec_err then
        return nil, "Failed to get operation: " .. exec_err
    end

    if #rows == 0 then
        return nil, "Operation not found"
    end

    return rows[1]
end

function operations_repo.update_status(id, status, ops_executed, error_msg)
    if not id or id == "" then
        return nil, "id is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local now = time.now()

    local query = sql.builder.update("kb_embed_operations")
        :set("status", status)
        :set("ops_executed", ops_executed or 0)
        :set("updated_at", db:type() == sql.type.SQLITE and now:unix() or now:format(time.RFC3339))
        :where("id = ?", id)

    if error_msg then
        query = query:set("error", error_msg)
    end

    local executor = query:run_with(db)
    local result, exec_err = executor:exec()

    db:release()

    if exec_err then
        return nil, "Failed to update operation: " .. exec_err
    end

    if result.rows_affected == 0 then
        return nil, "Operation not found"
    end

    return {
        id = id,
        status = status,
        updated = true
    }
end

function operations_repo.list_by_component(component_id, options)
    options = options or {}
    local limit = options.limit or 50
    local offset = options.offset or 0

    if not component_id or component_id == "" then
        return nil, "component_id is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("id", "component_id", "upload_uuid", "status", "error", "ops_executed", "created_at", "updated_at")
        :from("kb_embed_operations")
        :where("component_id = ?", component_id)
        :order_by("created_at DESC")
        :limit(limit)
        :offset(offset)

    if options.status then
        query = query:where("status = ?", options.status)
    end

    local executor = query:run_with(db)
    local rows, exec_err = executor:query()

    db:release()

    if exec_err then
        return nil, "Failed to list operations: " .. exec_err
    end

    return rows
end

function operations_repo.count_by_component(component_id, options)
    options = options or {}

    if not component_id or component_id == "" then
        return nil, "component_id is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("COUNT(*) as count")
        :from("kb_embed_operations")
        :where("component_id = ?", component_id)

    if options.status then
        query = query:where("status = ?", options.status)
    end

    local executor = query:run_with(db)
    local rows, exec_err = executor:query()

    db:release()

    if exec_err then
        return nil, "Failed to count operations: " .. exec_err
    end

    return rows[1].count
end

return operations_repo
