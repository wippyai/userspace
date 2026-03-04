local docker_client = require("docker_client")
local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")
local images_repo = require("images_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    return sql.get(db_id)
end

local function map_state(state: string): string
    if state == "running" then return "running"
    elseif state == "exited" or state == "dead" then return "stopped"
    elseif state == "created" or state == "restarting" then return "pending"
    elseif state == "paused" then return "running"
    else return "stopped"
    end
end

local function handle(input: table?)
    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local db, db_err = get_db()
    if db_err then
        return { success = false, error = tostring(db_err) }
    end

    local stats = {
        containers_synced = 0,
        containers_updated = 0,
        images_synced = 0,
        images_updated = 0,
    }

    -- sync containers
    local docker_containers, c_err = docker:list_containers()
    if not c_err and docker_containers then
        local existing = containers_repo.list(db, { limit = 10000 })
        local by_docker_id = {}
        for _, c in ipairs(existing) do
            if c.docker_id and c.docker_id ~= "" then
                by_docker_id[tostring(c.docker_id)] = c
            end
        end

        for _, dc in ipairs(docker_containers) do
            local docker_id = tostring(dc.Id or "")
            if docker_id == "" then goto next_container end

            local status = map_state(tostring(dc.State or "unknown"))
            local image = tostring(dc.Image or "unknown")
            local command = dc.Command and tostring(dc.Command) or ""

            local name = nil
            if dc.Names and type(dc.Names) == "table" and #dc.Names > 0 then
                name = tostring(dc.Names[1]):gsub("^/", "")
            end

            local ex = by_docker_id[docker_id]
            if ex then
                if tostring(ex.status) ~= status then
                    containers_repo.update_status(db, tostring(ex.id), status, {
                        docker_id = docker_id,
                    })
                    stats.containers_updated = stats.containers_updated + 1
                end
            else
                local id, create_err = containers_repo.create(db, {
                    image = image,
                    command = command,
                    name = name,
                    labels = { source = "synced" },
                    persist_logs = false,
                })
                if id and not create_err then
                    containers_repo.update_status(db, id, status, {
                        docker_id = docker_id,
                    })
                    stats.containers_synced = stats.containers_synced + 1
                end
            end

            ::next_container::
        end
    end

    -- sync images
    local docker_images, i_err = docker:list_images()
    if not i_err and docker_images then
        local managed = images_repo.list(db)
        local managed_by_tag = {}
        for _, m in ipairs(managed) do
            local key = tostring(m.name) .. ":" .. tostring(m.tag)
            managed_by_tag[key] = m
        end

        for _, img in ipairs(docker_images) do
            local tags = img.RepoTags or {}
            for _, tag in ipairs(tags) do
                if tag ~= "<none>:<none>" then
                    local img_name, ver = tag:match("^(.+):(.+)$")
                    if img_name then
                        local existing_img = managed_by_tag[tag]
                        if existing_img then
                            images_repo.update_status(db, tostring(existing_img.id), "available", {
                                docker_id = tostring(img.Id or ""),
                                size = tonumber(img.Size) or 0,
                            })
                            stats.images_updated = stats.images_updated + 1
                        else
                            images_repo.create(db, {
                                name = tostring(img_name),
                                tag = tostring(ver),
                                source = "synced",
                                status = "available",
                                docker_id = tostring(img.Id or ""),
                                size = tonumber(img.Size) or 0,
                            })
                            stats.images_synced = stats.images_synced + 1
                        end
                    end
                end
            end
        end
    end

    db:release()

    -- fetch networks and volumes live
    local networks = {}
    local net_list, net_err = docker:list_networks()
    if not net_err and net_list then
        for _, n in ipairs(net_list) do
            local container_count = 0
            if n.Containers and type(n.Containers) == "table" then
                for _ in pairs(n.Containers) do
                    container_count = container_count + 1
                end
            end
            table.insert(networks, {
                id = n.Id,
                name = n.Name,
                driver = n.Driver,
                scope = n.Scope,
                internal = n.Internal or false,
                containers = container_count,
            })
        end
    end

    local volumes = {}
    local vol_data, vol_err = docker:list_volumes()
    if not vol_err and vol_data then
        local vol_list = vol_data.Volumes or {}
        for _, v in ipairs(vol_list) do
            table.insert(volumes, {
                name = v.Name,
                driver = v.Driver,
                mountpoint = v.Mountpoint,
                scope = v.Scope,
            })
        end
    end

    return {
        success = true,
        stats = stats,
        networks = networks,
        volumes = volumes,
    }
end

return { handle = handle }
