local json = require("json")
local uuid = require("uuid")

local containers = {}

local function safe_json_decode(raw: string): table?
    if not raw then
        return nil
    end
    if raw == "" then
        return nil
    end
    local ok, result = pcall(json.decode, tostring(raw))
    if ok and type(result) == "table" then
        return result :: table
    end
    return nil
end

function containers.create(db, spec: {
    id: string?,
    name: string?,
    image: string,
    command: string?,
    env: {[string]: string}?,
    volumes: table?,
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
    health_check: table?,
    labels: table?,
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
    })

    local _, exec_err = db:execute([[
        INSERT INTO containers (id, name, image, command, config, status, labels,
            callback_pid, callback_topic, persist_logs, created_by, created_at)
        VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?)
    ]], {
        id, spec.name, spec.image, spec.command, config_json,
        labels_json, spec.callback_pid, spec.callback_topic,
        spec.persist_logs ~= false and 1 or 0, spec.created_by, now
    })

    if exec_err then
        return nil, "failed to insert container: " .. tostring(exec_err)
    end

    return id, nil
end

function containers.get(db, id: string): (table?, string?)
    local rows, query_err = db:query("SELECT * FROM containers WHERE id = ?", { id })
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
    limit: number?,
}?)
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

    local query = "SELECT * FROM containers"
    if #where > 0 then
        query = query .. " WHERE " .. table.concat(where, " AND ")
    end
    query = query .. " ORDER BY created_at DESC"

    if f.limit then
        query = query .. " LIMIT ?"
        table.insert(params, f.limit)
    end

    local rows, query_err = db:query(query, params)
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
    return rows
end

function containers.list_pending(db)
    local rows, query_err = db:query(
        "SELECT * FROM containers WHERE status = 'pending' ORDER BY created_at ASC"
    )
    if query_err or not rows then
        return {}
    end
    for _, row in ipairs(rows) do
        if row.config and row.config ~= "" then
            row.config = safe_json_decode(tostring(row.config))
        end
    end
    return rows
end

function containers.claim(db, id: string): boolean
    local result = db:execute(
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

    if f.docker_id then
        table.insert(sets, "docker_id = ?")
        table.insert(params, f.docker_id)
    end
    if f.exit_code ~= nil then
        table.insert(sets, "exit_code = ?")
        table.insert(params, f.exit_code)
    end
    if f.error then
        table.insert(sets, "error = ?")
        table.insert(params, f.error)
    end
    if f.started_at then
        table.insert(sets, "started_at = ?")
        table.insert(params, f.started_at)
    end
    if f.stopped_at then
        table.insert(sets, "stopped_at = ?")
        table.insert(params, f.stopped_at)
    end

    table.insert(params, id)
    local _, exec_err = db:execute(
        "UPDATE containers SET " .. table.concat(sets, ", ") .. " WHERE id = ?",
        params
    )

    if exec_err then
        return "failed to update status: " .. tostring(exec_err)
    end

    return nil
end

function containers.append_log(db, container_id: string, stream: string, line: string): string?
    local _, err = db:execute([[
        INSERT INTO container_logs (container_id, stream, line, ts) VALUES (?, ?, ?, ?)
    ]], { container_id, stream, line, os.time() })
    if err then
        return "failed to append log: " .. tostring(err)
    end
    return nil
end

function containers.get_logs(db, container_id: string): any
    local rows, err = db:query(
        "SELECT stream, line FROM container_logs WHERE container_id = ? ORDER BY id ASC",
        { container_id }
    )
    if err or not rows then
        return {}
    end
    return rows :: table
end

function containers.update_name(db, id: string, name: string): string?
    local _, exec_err = db:execute("UPDATE containers SET name = ? WHERE id = ?", { name, id })
    if exec_err then
        return "failed to update name: " .. tostring(exec_err)
    end
    return nil
end

function containers.delete(db, id: string): string?
    local _, exec_err = db:execute("DELETE FROM containers WHERE id = ?", { id })
    if exec_err then
        return "failed to delete container: " .. tostring(exec_err)
    end
    return nil
end

return containers
