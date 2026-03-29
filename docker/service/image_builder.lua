local sql = require("sql")
local json = require("json")
local time = require("time")
local consts = require("consts")
local images_repo = require("images_repo")
local tar = require("tar")
local docker_client = require("docker_client")
local helpers = require("helpers")

local logger = require("logger")

local BUILD_TIMEOUT = "600s"

local function notify_root(root_pid, topic, payload)
    if root_pid then
        helpers.send_json(root_pid, topic, payload)
    end
end

local function run_build(db_id, docker, build, root_pid, log)
    local build_id = tostring(build.id)
    local image_id = tostring(build.image_id)

    local db, db_err = sql.get(db_id)
    if db_err then
        notify_root(root_pid, consts.topic.IMAGE_BUILD_STATUS, {
            build_id = build_id,
            image_id = image_id,
            status = consts.build_status.FAILED,
            error = "db unavailable",
        })
        return
    end

    local image = images_repo.get(db, image_id)
    if not image then
        images_repo.update_build(db, build_id, consts.build_status.FAILED, {
            error = "image record not found",
        })
        db:release()
        notify_root(root_pid, consts.topic.IMAGE_BUILD_STATUS, {
            build_id = build_id,
            image_id = image_id,
            status = consts.build_status.FAILED,
            error = "image record not found",
        })
        return
    end

    local image_name = tostring(image.name)
    local image_tag = tostring(image.tag)

    images_repo.update_status(db, image_id, consts.image_status.BUILDING)
    notify_root(root_pid, consts.topic.IMAGE_BUILD_STATUS, {
        build_id = build_id,
        image_id = image_id,
        status = consts.build_status.BUILDING,
    })

    local tar_data = tar.create({
        { name = "Dockerfile", content = tostring(build.dockerfile) },
    })

    -- Release DB before blocking Docker build
    db:release()

    local lines, build_err = docker:build_image(tar_data, image_name, image_tag)

    -- Reacquire DB for result storage
    local db2, db2_err = sql.get(db_id)
    if db2_err then
        notify_root(root_pid, consts.topic.IMAGE_BUILD_STATUS, {
            build_id = build_id,
            image_id = image_id,
            status = consts.build_status.FAILED,
            error = "db unavailable after build",
        })
        return
    end
    db = db2

    if build_err then
        images_repo.update_status(db, image_id, consts.image_status.FAILED, {
            error = tostring(build_err),
        })
        images_repo.update_build(db, build_id, consts.build_status.FAILED, {
            error = tostring(build_err),
        })
        db:release()
        notify_root(root_pid, consts.topic.IMAGE_BUILD_STATUS, {
            build_id = build_id,
            image_id = image_id,
            status = consts.build_status.FAILED,
            error = tostring(build_err),
        })
        return
    end

    local log_parts = {}
    local has_error = false
    local error_msg = ""

    for _, line in ipairs(lines or {}) do
        local text = ""
        if line.stream then
            text = tostring(line.stream)
        elseif line.status then
            text = tostring(line.status)
            if line.progress then
                text = text .. " " .. tostring(line.progress)
            end
        elseif line.error then
            has_error = true
            error_msg = tostring(line.error)
            text = "ERROR: " .. error_msg
        end

        if text ~= "" then
            table.insert(log_parts, text)
            notify_root(root_pid, consts.topic.IMAGE_BUILD_LOG, {
                build_id = build_id,
                image_id = image_id,
                line = text,
            })
        end
    end

    local full_log = table.concat(log_parts, "")

    if has_error then
        images_repo.update_status(db, image_id, consts.image_status.FAILED, {
            error = error_msg,
        })
        images_repo.update_build(db, build_id, consts.build_status.FAILED, {
            build_log = full_log,
            error = error_msg,
        })
        db:release()
        notify_root(root_pid, consts.topic.IMAGE_BUILD_STATUS, {
            build_id = build_id,
            image_id = image_id,
            status = consts.build_status.FAILED,
            error = error_msg,
        })
        return
    end

    local full_tag = image_name .. ":" .. image_tag
    local info, inspect_err = docker:inspect_image(full_tag)
    local docker_image_id = ""
    local size = 0
    if info and not inspect_err then
        docker_image_id = tostring(info.Id or "")
        size = tonumber(info.Size) or 0
    end

    images_repo.update_status(db, image_id, consts.image_status.AVAILABLE, {
        docker_id = docker_image_id,
        size = size,
    })
    images_repo.update_build(db, build_id, consts.build_status.COMPLETED, {
        build_log = full_log,
    })

    db:release()

    notify_root(root_pid, consts.topic.IMAGE_BUILD_STATUS, {
        build_id = build_id,
        image_id = image_id,
        status = consts.build_status.COMPLETED,
    })

    log:info("build completed", { image = full_tag, build_id = build_id })
end

local image_builder = {}

function image_builder.run(config: {db_id: string, socket_path: string?})
    local log = logger:named("docker.image_builder")

    local db, db_err = sql.get(config.db_id)
    if db_err then
        return nil, "failed to get database: " .. tostring(db_err)
    end

    local docker, docker_err = docker_client.new(config.socket_path)
    if docker_err then
        db:release()
        return nil, "failed to connect to Docker: " .. tostring(docker_err)
    end

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    local events = process.events()
    local inbox = process.inbox()

    log:info("started")

    while true do
        local result = channel.select({
            events:case_receive(),
            inbox:case_receive(),
        })

        if result.channel == events then
            if result.value.kind == process.event.CANCEL then
                break
            end
        elseif result.channel == inbox then
            local msg = result.value
            local topic = msg:topic()

            if topic == consts.topic.IMAGE_BUILD_NEW then
                local payload = helpers.extract_payload(msg)
                if payload and payload.build_id then
                    local build_id = tostring(payload.build_id)
                    local claimed = images_repo.claim_build(db, build_id)
                    if claimed then
                        local build = images_repo.get_build(db, build_id)
                        if build then
                            coroutine.spawn(function()
                                run_build(config.db_id, docker, build, root_pid, log)
                            end)
                        end
                    end
                end
            end
        end
    end

    db:release()
    return { status = "image_builder_shutdown" }
end

return image_builder
