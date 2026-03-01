local sql = require("sql")
local env = require("env")
local images_repo = require("images_repo")
local docker_client = require("docker_client")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: {id: string})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end

    local db, err = get_db()
    if err then
        return { success = false, error = tostring(err) }
    end

    local image = images_repo.get(db, input.id)
    if not image then
        db:release()
        return { success = false, error = "image not found" }
    end

    local full_tag = tostring(image.name) .. ":" .. tostring(image.tag)

    local warning = nil
    local docker = docker_client.new()
    if docker then
        local _, rm_err = docker:remove_image(full_tag, true)
        if rm_err then
            warning = "remove_image: " .. tostring(rm_err)
        end
    end

    images_repo.delete(db, input.id)
    db:release()

    local result: {[string]: any} = { success = true }
    if warning then
        result.warning = warning
    end

    return result
end

return { handle = handle }
