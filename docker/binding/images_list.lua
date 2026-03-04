local sql = require("sql")
local env = require("env")
local images_repo = require("images_repo")
local docker_client = require("docker_client")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: table?)
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local docker_images, list_err = docker:list_images()
    if list_err then
        return { success = false, error = "failed to list images: " .. tostring(list_err) }
    end

    local db, db_err = get_db()
    if db_err then
        return { success = false, error = tostring(db_err) }
    end

    local managed = images_repo.list(db)
    db:release()

    local managed_by_tag = {}
    for _, m in ipairs(managed) do
        local key = tostring(m.name) .. ":" .. tostring(m.tag)
        managed_by_tag[key] = m
    end

    local result = {}
    for _, img in ipairs(docker_images or {}) do
        local tags = img.RepoTags or {}
        for _, tag in ipairs(tags) do
            if tag ~= "<none>:<none>" then
                local name, ver = tag:match("^(.+):(.+)$")
                if name then
                    local m = managed_by_tag[tag]
                    table.insert(result, {
                        id = m and m.id or img.Id,
                        docker_id = img.Id,
                        name = name,
                        tag = ver,
                        size = img.Size,
                        created = img.Created,
                        managed = m ~= nil,
                        source = m and m.source or nil,
                        status = m and m.status or "available",
                    })
                    if m then
                        managed_by_tag[tag] = nil
                    end
                end
            end
        end
    end

    for _, m in pairs(managed_by_tag) do
        local st = m.status
        if st == "building" or st == "pulling" then
            table.insert(result, {
                id = m.id,
                docker_id = m.docker_id,
                name = m.name,
                tag = m.tag,
                size = m.size,
                created = m.created_at,
                managed = true,
                source = m.source,
                status = st,
            })
        end
    end

    return { success = true, images = result }
end

return { handle = handle }
