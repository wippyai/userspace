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

-- Write a file into a running container at `path` (parent dirs are created). The
-- bytes travel as a tar stream over Docker's archive endpoint - binary-safe and
-- unbounded, no exec/base64 channel.
local function handle(input: {
    id: string,
    path: string,
    content: string?,
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

    local content = input.content or ""
    local tar_data = tar.create_file(input.path, content)

    local _, put_err = docker:put_archive(tostring(container.docker_id), "/", tar_data)
    if put_err then
        return { success = false, error = tostring(put_err) }
    end

    return { success = true, path = input.path, bytes = #content }
end

return { handle = handle }
