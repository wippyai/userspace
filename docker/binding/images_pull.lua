local sql = require("sql")
local env = require("env")
local consts = require("consts")
local images_repo = require("images_repo")
local docker_client = require("docker_client")

local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

local function handle(input: {image: string, tag: string?})
    if not input.image or input.image == "" then
        return { success = false, error = "image is required" }
    end

    local image_name = tostring(input.image)
    local image_tag = (input.tag and input.tag ~= "") and tostring(input.tag) or "latest"

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local _, pull_err = docker:pull_image(image_name, image_tag)
    if pull_err then
        return { success = false, error = "pull failed: " .. tostring(pull_err) }
    end

    local full_tag = image_name .. ":" .. image_tag
    local info = docker:inspect_image(full_tag)
    local docker_id = ""
    local size = 0
    if info then
        docker_id = tostring(info.Id or "")
        size = tonumber(info.Size) or 0
    end

    local db, db_err = get_db()
    if db_err then
        return { success = false, error = tostring(db_err) }
    end

    local existing = images_repo.get_by_name_tag(db, image_name, image_tag)
    local id: string?
    if existing then
        id = tostring(existing.id)
        images_repo.update_status(db, id, consts.image_status.AVAILABLE, {
            docker_id = docker_id,
            size = size,
        })
    else
        local create_err
        id, create_err = images_repo.create(db, {
            name = image_name,
            tag = image_tag,
            source = "pulled",
            status = consts.image_status.AVAILABLE,
            docker_id = docker_id,
            size = size,
        })
        if create_err then
            db:release()
            return { success = false, error = tostring(create_err) }
        end
    end

    db:release()

    return {
        success = true,
        id = id,
        name = image_name,
        tag = image_tag,
        status = consts.image_status.AVAILABLE,
    }
end

return { handle = handle }
