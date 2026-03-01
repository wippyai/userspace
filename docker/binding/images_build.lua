local sql = require("sql")
local json = require("json")
local env = require("env")
local consts = require("consts")
local images_repo = require("images_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function handle(input: {
    name: string,
    tag: string?,
    dockerfile: string,
    stream: table?,
})
    if not input.name or input.name == "" then
        return { success = false, error = "name is required" }
    end

    if not input.dockerfile or input.dockerfile == "" then
        return { success = false, error = "dockerfile is required" }
    end

    local image_name = tostring(input.name)
    local image_tag = (input.tag and input.tag ~= "") and tostring(input.tag) or "latest"
    local dockerfile = tostring(input.dockerfile)

    local db, db_err = get_db()
    if db_err then
        return { success = false, error = tostring(db_err) }
    end

    local image_id, img_err = images_repo.create(db, {
        name = image_name,
        tag = image_tag,
        source = "built",
        status = consts.image_status.BUILDING,
    })

    if img_err then
        db:release()
        return { success = false, error = tostring(img_err) }
    end

    local build_id, build_err = images_repo.create_build(db, {
        image_id = image_id,
        dockerfile = dockerfile,
    })

    if build_err then
        images_repo.delete(db, image_id)
        db:release()
        return { success = false, error = tostring(build_err) }
    end

    db:release()

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if root_pid then
        process.send(root_pid, consts.topic.IMAGE_BUILD_NEW, json.encode({
            build_id = build_id,
        }))

        if input.stream and input.stream.reply_to then
            process.send(root_pid, consts.topic.IMAGE_BUILD_SUBSCRIBE, json.encode({
                build_id = build_id,
                pid = tostring(input.stream.reply_to),
            }))
        end
    end

    return {
        success = true,
        id = image_id,
        build_id = build_id,
        status = "building",
    }
end

return { handle = handle }
