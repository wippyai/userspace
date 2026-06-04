local json = require("json")
local uuid = require("uuid")
local sql = require("sql")

local containers = {}

local function safe_json_decode(raw: string): table?
    if not raw or raw == "" then
        return nil
    end
    local result, err = json.decode(tostring(raw))
    if err or type(result) ~= "table" then
        return nil
    end
    return result :: table
end

local function is_postgres(db): boolean
    if type(db) ~= "table" and type(db) ~= "userdata" then return false end
    if type(db.type) ~= "function" then return false end
    local db_type = db:type()
    if sql.type and db_type == sql.type.POSTGRES then return true end
    return tostring(db_type):lower() == "postgres"
end

local function bind_sql(db, sql_text: string): string
    if not is_postgres(db) then return sql_text end
    local i = 0
    return (sql_text:gsub("%?", function()
        i = i + 1
        return "$" .. tostring(i)
    end))
end

local function db_execute(db, sql_text: string, args: any?)
    return db:execute(bind_sql(db, sql_text), args)
end

local function db_query(db, sql_text: string, args: any?)
    return db:query(bind_sql(db, sql_text), args)
end

function containers.create(db, spec: {
    id: string?,
    name: string?,
    image: string,
    command: string?,
    env: {[string]: string}?,
    volumes: {host: string, container: string, mode: string?}[]?,
    ports: {host: number, container: number, protocol: string?}[]?,
    network: string?,
    work_dir: string?,
    user: string?,
    memory_limit: number?,
    cpu_quota: number?,
    auto_remove: boolean?,
    interactive: boolean?,
    restart_policy: string?,
    max_restarts: number?,
    health_check: {test: {string}?, interval: number?, timeout: number?, retries: number?}?,
    extra_hosts: {string}?,
    hostname: string?,
    cap_add: {string}?,
    dns: {string}?,
    group_add: {string}?,
    devices: {table}?,
    device_requests: {table}?,
    args: {string}?,
    entrypoint: {string}?,
    group_id: string?,
    labels: {[string]: string}?,
    callback_pid: string?,
    callback_topic: string?,
    persist_logs: boolean?,
    created_by: string?,
}): (string?, string?)
    local id = spec.id or uuid.v4()
    local now = os.time()

    local labels_json = spec.labels and json.encode(spec.labels) or nil

    local config_json = json.encode({
        image          = spec.image,
        command        = spec.command,
        env            = spec.env,
        volumes        = spec.volumes,
        ports          = spec.ports,
        network        = spec.network,
        work_dir       = spec.work_dir,
        user           = spec.user,
        memory_limit   = spec.memory_limit,
        cpu_quota      = spec.cpu_quota,
        auto_remove    = spec.auto_remove,
        interactive    = spec.interactive,
        restart_policy = spec.restart_policy,
        max_restarts   = spec.max_restarts,
        health_check   = spec.health_check,
        extra_hosts    = spec.extra_hosts,
        hostname       = spec.hostname,
        cap_add        = spec.cap_add,
        dns            = spec.dns,
        group_add      = spec.group_add,
        devices        = spec.devices,
        device_requests = spec.device_requests,
        args           = spec.args,
        entrypoint     = spec.entrypoint,
    })

    local _, exec_err = db_execute(db, [[
        INSERT INTO containers (id, name, image, command, config, status, group_id, labels,
            callback_pid, callback_topic, persist_logs, created_by, created_at)
        VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?)
    ]], {
        id, spec.name, spec.image, spec.command, config_json,
        spec.group_id, labels_json, spec.callback_pid, spec.callback_topic,
        spec.persist_logs ~= false and 1 or 0, spec.created_by, now
    })

    if exec_err then
        return nil, "failed to insert container: " .. tostring(exec_err)
    end

    return id, nil
end

function containers.get(db, id: string): (table?, string?)
    local rows, query_err = db_query(db, "SELECT * FROM containers WHERE id = ?", { id })
    if query_err then
        return nil, "failed to get container: " .. tostring(query_err)
    end
    if not rows or #rows == 0 then
        return nil, nil
    end
    local row = rows[1]
    if row.labels and row.labels ~= "" then
        row.labels = safe_json_decode(tostring(row.labels))
    end
    if row.config and row.config ~= "" then
        row.config = safe_json_decode(tostring(row.config))
    end
    return row
end

function containers.list(db, filter: {
    status: string?,
    status_not: string?,
    group_id: string?,
    limit: number?,
}?): {table}
    local f = filter or {}
    local where = {}
    local params = {}

    if f.status then
        table.insert(where, "status = ?")
        table.insert(params, f.status)
    end

    if f.status_not then
        table.insert(where, "status != ?")
        table.insert(params, f.status_not)
    end

    if f.group_id then
        table.insert(where, "group_id = ?")
        table.insert(params, f.group_id)
    end

    local query = "SELECT * FROM containers"
    if #where > 0 then
        query = query .. " WHERE " .. table.concat(where, " AND ")
    end
    query = query .. " ORDER BY created_at DESC"

    if f.limit then
        query = query .. " LIMIT ?"
        table.insert(params, f.limit)
    end

    local rows, query_err = db_query(db, query, params)
    if query_err or not rows then
        return {}
    end

    for _, row in ipairs(rows) do
        if row.labels and row.labels ~= "" then
            row.labels = safe_json_decode(tostring(row.labels))
        end
        if row.config and row.config ~= "" then
            row.config = safe_json_decode(tostring(row.config))
        end
    end
    return rows :: {table}
end

function containers.list_pending(db): {table}
    local rows, query_err = db_query(db,
        "SELECT * FROM containers WHERE status = 'pending' ORDER BY created_at ASC"
    )
    if query_err or not rows then
        return {}
    end
    local result: {table} = rows :: {table}
    for _, row in ipairs(result) do
        if row.labels and row.labels ~= "" then
            row.labels = safe_json_decode(tostring(row.labels))
        end
        if row.config and row.config ~= "" then
            row.config = safe_json_decode(tostring(row.config))
        end
    end
    return result
end

function containers.claim(db, id: string): boolean
    local result = db_execute(db,
        "UPDATE containers SET status = 'claimed' WHERE id = ? AND status = 'pending'",
        { id }
    )
    if result and result.rows_affected and result.rows_affected > 0 then
        return true
    end
    return false
end

function containers.update_status(db, id: string, status: string, fields: {
    docker_id: string?,
    exit_code: number?,
    error: string?,
    started_at: number?,
    stopped_at: number?,
}?): string?
    local f = fields or {}
    local sets = { "status = ?" }
    local params = { status }

    if f.docker_id ~= nil then
        table.insert(sets, "docker_id = ?")
        table.insert(params, f.docker_id)
    end
    if f.exit_code ~= nil then
        table.insert(sets, "exit_code = ?")
        table.insert(params, f.exit_code)
    end
    if f.error ~= nil then
        if f.error == "" then
            table.insert(sets, "error = NULL")
        else
            table.insert(sets, "error = ?")
            table.insert(params, f.error)
        end
    end
    if f.started_at ~= nil then
        table.insert(sets, "started_at = ?")
        table.insert(params, f.started_at)
    end
    if f.stopped_at ~= nil then
        table.insert(sets, "stopped_at = ?")
        table.insert(params, f.stopped_at)
    end

    table.insert(params, id)
    local _, exec_err = db_execute(db,
        "UPDATE containers SET " .. table.concat(sets, ", ") .. " WHERE id = ?",
        params
    )

    if exec_err then
        return "failed to update status: " .. tostring(exec_err)
    end

    return nil
end

function containers.append_log(db, container_id: string, stream: string, line: string): string?
    local _, err = db_execute(db, [[
        INSERT INTO container_logs (container_id, stream, line, ts) VALUES (?, ?, ?, ?)
    ]], { container_id, stream, line, os.time() })
    if err then
        return "failed to append log: " .. tostring(err)
    end
    return nil
end

function containers.get_logs(db, container_id: string, limit: number?): ({table}, string?)
    local query = "SELECT stream, line, ts FROM container_logs WHERE container_id = ? ORDER BY id ASC"
    local params: {any} = { container_id }
    if limit then
        query = query .. " LIMIT ?"
        table.insert(params, limit)
    end
    local rows, err = db_query(db, query, params)
    if err then
        return {}, "failed to get logs: " .. tostring(err)
    end
    return (rows or {}) :: {table}, nil
end

function containers.list_by_group(db, group_id: string): {table}
    local rows, query_err = db_query(db,
        "SELECT * FROM containers WHERE group_id = ? ORDER BY created_at DESC",
        { group_id }
    )
    if query_err or not rows then
        return {}
    end
    for _, row in ipairs(rows) do
        if row.labels and row.labels ~= "" then
            row.labels = safe_json_decode(tostring(row.labels))
        end
        if row.config and row.config ~= "" then
            row.config = safe_json_decode(tostring(row.config))
        end
    end
    return rows :: {table}
end

function containers.delete_by_group(db, group_id: string): (number, string?)
    local rows = containers.list_by_group(db, group_id)
    local count = 0
    for _, row in ipairs(rows) do
        local err = containers.delete(db, tostring(row.id))
        if not err then
            count = count + 1
        end
    end
    return count, nil
end

function containers.update_name(db, id: string, name: string): string?
    local _, exec_err = db_execute(db, "UPDATE containers SET name = ? WHERE id = ?", { name, id })
    if exec_err then
        return "failed to update name: " .. tostring(exec_err)
    end
    return nil
end

function containers.delete(db, id: string): string?
    db_execute(db, "DELETE FROM container_logs WHERE container_id = ?", { id })
    local _, exec_err = db_execute(db, "DELETE FROM containers WHERE id = ?", { id })
    if exec_err then
        return "failed to delete container: " .. tostring(exec_err)
    end
    return nil
end

return containers
