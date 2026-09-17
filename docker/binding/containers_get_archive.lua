local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")
local docker_client = require("docker_client")
local consts = require("consts")
local tar = require("tar")

local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

-- Read a file out of a running container at `path`. Docker returns the path as a
-- tar stream; the first regular-file entry is unpacked and returned. Binary-safe
-- and unbounded, no exec/base64 channel.
local function handle(input: {
    id: string,
    path: string,
})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end
    if not input.path or input.path == "" then
        return { success = false, error = "path is required" }
    end

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local container = containers_repo.get(db, input.id)
    if not container then
        db:release()
        return { success = false, error = "container not found" }
    end
    if not container.docker_id or container.docker_id == "" then
        db:release()
        return { success = false, error = "container has no docker_id" }
    end
    if container.status ~= consts.status.RUNNING then
        db:release()
        return { success = false, error = "container is not running (status: " .. tostring(container.status) .. ")" }
    end

    db:release()

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = tostring(docker_err) }
    end

    local tar_data, get_err = docker:get_archive(tostring(container.docker_id), input.path)
    if get_err then
        return { success = false, error = tostring(get_err) }
    end

    local content, name, is_dir = tar.read_first(tostring(tar_data))
    if is_dir then
        return { success = false, error = "path is a directory, not a file: " .. input.path }
    end
    if content == nil then
        return { success = false, error = "no file at path: " .. input.path }
    end

    return { success = true, path = input.path, name = name, content = content, size = #content }
end

return { handle = handle }
