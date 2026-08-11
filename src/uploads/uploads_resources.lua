local sql = require("sql")
local env = require("env")
local fs = require("fs")
local cloudstorage = require("cloudstorage")
local registry = require("registry")

local ENV = table.freeze({
    DATABASE = "userspace.uploads.env:database_resource",
    STORAGE = "userspace.uploads.env:storage_id",
    STORAGE_S3 = "userspace.uploads.env:storage_s3",
})

local DEFAULTS = table.freeze({
    DATABASE = "app:db",
    STORAGE = "app:uploads",
    STORAGE_S3 = "app:uploads.s3",
})

local resources = {}

function resources.get_db(): (sql.DB?, string?)
    local id = env.get(ENV.DATABASE) or DEFAULTS.DATABASE
    local db, err = sql.get(id)
    if err then
        return nil, "Failed to connect to database: " .. err
    end
    return db
end

function resources.get_storage_id(storage_id)
    if storage_id and storage_id ~= "" then
        return storage_id
    end

    return env.get(ENV.STORAGE) or DEFAULTS.STORAGE
end

function resources.get_storage(storage_id)
    local storage, err = fs.get(resources.get_storage_id(storage_id))
    if err then
        return nil, "Failed to get storage: " .. err
    end
    return storage
end

function resources.get_s3_id()
    return env.get(ENV.STORAGE_S3) or DEFAULTS.STORAGE_S3
end

function resources.get_s3(storage_id)
    local id = storage_id
    if not id or id == "" then
        id = resources.get_s3_id()
    end

    local s3, err = cloudstorage.get(id)
    if err then
        return nil, "Failed to get S3 storage: " .. err
    end
    return s3
end

function resources.is_cloud_storage(storage_id)
    local id = resources.get_storage_id(storage_id)
    if id == resources.get_s3_id() then
        return true
    end

    local entry = registry.get(id)
    if entry and entry.kind then
        return tostring(entry.kind):find("cloudstorage.", 1, true) == 1
    end

    return false
end

return resources
