local json = require("json")
local uuid = require("uuid")
local consts = require("consts")

local images = {}

function images.create(db, spec: {
    id: string?,
    name: string,
    tag: string?,
    source: string,
    status: string?,
    docker_id: string?,
    size: number?,
}): (string?, string?)
    local id = spec.id or uuid.v4()
    local now = os.time()

    local _, err = db:execute([[
        INSERT INTO images (id, docker_id, name, tag, source, status, size, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        id, spec.docker_id, spec.name, spec.tag or "latest",
        spec.source, spec.status or consts.image_status.AVAILABLE, spec.size, now,
    })

    if err then
        return nil, "failed to insert image: " .. tostring(err)
    end

    return id, nil
end

function images.get(db, id: string): (table?, string?)
    local rows, err = db:query("SELECT * FROM images WHERE id = ?", { id })
    if err then
        return nil, "failed to get image: " .. tostring(err)
    end
    if not rows or #rows == 0 then
        return nil, nil
    end
    return rows[1] :: table
end

function images.get_by_name_tag(db, name: string, tag: string?): (table?, string?)
    local t = tag or "latest"
    local rows, err = db:query(
        "SELECT * FROM images WHERE name = ? AND tag = ?", { name, t }
    )
    if err then
        return nil, "failed to get image: " .. tostring(err)
    end
    if not rows or #rows == 0 then
        return nil, nil
    end
    return rows[1] :: table
end

function images.list(db, filter: {status: string?, source: string?}?)
    local f = filter or {}
    local where = {}
    local params = {}

    if f.status then
        table.insert(where, "status = ?")
        table.insert(params, f.status)
    end

    if f.source then
        table.insert(where, "source = ?")
        table.insert(params, f.source)
    end

    local query = "SELECT * FROM images"
    if #where > 0 then
        query = query .. " WHERE " .. table.concat(where, " AND ")
    end
    query = query .. " ORDER BY created_at DESC"

    local rows, err = db:query(query, params)
    if err or not rows then
        return {}
    end
    return rows
end

function images.update_status(db, id: string, status: string, fields: {
    docker_id: string?,
    size: number?,
    error: string?,
}?): string?
    local f = fields or {}
    local sets = { "status = ?", "updated_at = ?" }
    local params = { status, os.time() }

    if f.docker_id then
        table.insert(sets, "docker_id = ?")
        table.insert(params, f.docker_id)
    end
    if f.size then
        table.insert(sets, "size = ?")
        table.insert(params, f.size)
    end
    if f.error then
        table.insert(sets, "error = ?")
        table.insert(params, f.error)
    end

    table.insert(params, id)
    local _, err = db:execute(
        "UPDATE images SET " .. table.concat(sets, ", ") .. " WHERE id = ?",
        params
    )

    if err then
        return "failed to update image status: " .. tostring(err)
    end
    return nil
end

function images.delete(db, id: string): string?
    local _, builds_err = db:execute("DELETE FROM image_builds WHERE image_id = ?", { id })
    if builds_err then
        return "failed to delete image builds: " .. tostring(builds_err)
    end

    local _, err = db:execute("DELETE FROM images WHERE id = ?", { id })
    if err then
        return "failed to delete image: " .. tostring(err)
    end
    return nil
end

function images.create_build(db, spec: {
    id: string?,
    image_id: string,
    dockerfile: string,
}): (string?, string?)
    local id = spec.id or uuid.v4()
    local now = os.time()

    local _, err = db:execute([[
        INSERT INTO image_builds (id, image_id, dockerfile, status, created_at)
        VALUES (?, ?, ?, 'pending', ?)
    ]], { id, spec.image_id, spec.dockerfile, now })

    if err then
        return nil, "failed to insert build: " .. tostring(err)
    end
    return id, nil
end

function images.get_build(db, id: string): (table?, string?)
    local rows, err = db:query("SELECT * FROM image_builds WHERE id = ?", { id })
    if err then
        return nil, "failed to get build: " .. tostring(err)
    end
    if not rows or #rows == 0 then
        return nil, nil
    end
    return rows[1] :: table
end

function images.claim_build(db, id: string): boolean
    local result = db:execute(
        "UPDATE image_builds SET status = 'building', started_at = ? WHERE id = ? AND status = 'pending'",
        { os.time(), id }
    )
    if result and result.rows_affected and result.rows_affected > 0 then
        return true
    end
    return false
end

function images.update_build(db, id: string, status: string, fields: {
    build_log: string?,
    error: string?,
}?): string?
    local f = fields or {}
    local sets = { "status = ?" }
    local params = { status }

    if status == consts.build_status.COMPLETED or status == consts.build_status.FAILED then
        table.insert(sets, "completed_at = ?")
        table.insert(params, os.time())
    end

    if f.build_log then
        table.insert(sets, "build_log = ?")
        table.insert(params, f.build_log)
    end
    if f.error then
        table.insert(sets, "error = ?")
        table.insert(params, f.error)
    end

    table.insert(params, id)
    local _, err = db:execute(
        "UPDATE image_builds SET " .. table.concat(sets, ", ") .. " WHERE id = ?",
        params
    )

    if err then
        return "failed to update build: " .. tostring(err)
    end
    return nil
end

return images
