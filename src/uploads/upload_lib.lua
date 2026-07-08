local uuid = require("uuid")
local json = require("json")
local time = require("time")
local queue = require("queue")
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")

local upload_repo = require("upload_repo")
local upload_type = require("upload_type")
local resources = require("uploads_resources")
local content_repo = require("content_repo")

local log = logger:named("upload_lib")

local QUEUE_ID = "userspace.uploads:process_queue"

local upload_lib = {}

local MIME_TYPES: {[string]: string} = {
    ["txt"] = "text/plain",
    ["html"] = "text/html",
    ["htm"] = "text/html",
    ["css"] = "text/css",
    ["csv"] = "text/csv",
    ["xml"] = "application/xml",
    ["md"] = "text/markdown",
    ["pdf"] = "application/pdf",
    ["doc"] = "application/msword",
    ["docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ["xls"] = "application/vnd.ms-excel",
    ["xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ["ppt"] = "application/vnd.ms-powerpoint",
    ["pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ["odt"] = "application/vnd.oasis.opendocument.text",
    ["ods"] = "application/vnd.oasis.opendocument.spreadsheet",
    ["odp"] = "application/vnd.oasis.opendocument.presentation",
    ["rtf"] = "application/rtf",
    ["jpg"] = "image/jpeg",
    ["jpeg"] = "image/jpeg",
    ["png"] = "image/png",
    ["gif"] = "image/gif",
    ["bmp"] = "image/bmp",
    ["svg"] = "image/svg+xml",
    ["webp"] = "image/webp",
    ["tiff"] = "image/tiff",
    ["tif"] = "image/tiff",
    ["ico"] = "image/x-icon",
    ["mp3"] = "audio/mpeg",
    ["wav"] = "audio/wav",
    ["ogg"] = "audio/ogg",
    ["flac"] = "audio/flac",
    ["aac"] = "audio/aac",
    ["m4a"] = "audio/mp4",
    ["mp4"] = "video/mp4",
    ["avi"] = "video/x-msvideo",
    ["mov"] = "video/quicktime",
    ["wmv"] = "video/x-ms-wmv",
    ["mkv"] = "video/x-matroska",
    ["webm"] = "video/webm",
    ["flv"] = "video/x-flv",
    ["zip"] = "application/zip",
    ["rar"] = "application/x-rar-compressed",
    ["7z"] = "application/x-7z-compressed",
    ["tar"] = "application/x-tar",
    ["gz"] = "application/gzip",
    ["js"] = "application/javascript",
    ["json"] = "application/json",
    ["lua"] = "text/x-lua",
    ["py"] = "text/x-python",
    ["java"] = "text/x-java",
    ["c"] = "text/x-c",
    ["cpp"] = "text/x-c++",
    ["cs"] = "text/x-csharp",
    ["go"] = "text/x-go",
    ["rb"] = "text/x-ruby",
    ["php"] = "text/x-php",
    ["sql"] = "application/sql",
    ["ttf"] = "font/ttf",
    ["otf"] = "font/otf",
    ["woff"] = "font/woff",
    ["woff2"] = "font/woff2",
    ["eml"] = "message/rfc822",
    ["exe"] = "application/octet-stream",
    ["bin"] = "application/octet-stream",
    ["dmg"] = "application/x-apple-diskimage",
    ["iso"] = "application/x-iso9660-image",
}

local function generate_upload_id()
    return uuid.v4()
end

local function get_file_extension(filename)
    return filename:match("%.([^%.]+)$") or ""
end

local function get_mime_type_from_extension(filename)
    local ext = get_file_extension(filename):lower()
    if ext and MIME_TYPES[ext] then
        return MIME_TYPES[ext]
    end
    return "application/octet-stream"
end

local function determine_upload_type(mime_type, filename)
    local ext = get_file_extension(filename)
    local type_entry, err = upload_type.find_by_mime_or_ext(mime_type, ext)
    if not type_entry then
        return nil, "Unsupported file type: " .. (err or "unknown error")
    end
    return type_entry.id
end

local function publish_to_queue(upload_id)
    local payload = json.encode({ upload_id = upload_id })
    local _, err = queue.publish(QUEUE_ID, payload)
    if err then
        log:error("failed to enqueue upload", { upload_id = upload_id, error = err })
    end
end

local function invoke_on_delete(upload)
    if not upload.type_id or upload.type_id == "" then
        return
    end

    local on_delete, err = upload_type.get_on_delete(upload.type_id)
    if err or not on_delete or #on_delete == 0 then
        return
    end

    local actor = security.new_actor(tostring(upload.user_id), {
        context_id = "delete:" .. tostring(upload.uuid),
    })

    local executor = funcs.new()
        :with_context({
            upload_id = upload.uuid,
            user_id = upload.user_id,
            mime_type = upload.mime_type,
            type_id = upload.type_id,
        })
        :with_actor(actor)

    for i, stage in ipairs(on_delete) do
        local func_id = stage.func
        if func_id then
            local ok, result_or_err = pcall(function()
                return executor:call(tostring(func_id), {
                    upload_id = upload.uuid,
                    mime_type = upload.mime_type,
                    storage_id = upload.storage_id,
                    storage_path = upload.storage_path,
                    size = upload.size,
                    metadata = upload.metadata,
                    processor_id = func_id,
                })
            end)

            if not ok then
                log:error("on_delete stage failed", {
                    upload_id = upload.uuid,
                    stage = i,
                    func = func_id,
                    error = tostring(result_or_err),
                })
            else
                local result, call_err = result_or_err, nil
                if type(result_or_err) == "string" then
                    call_err = result_or_err
                end
                if call_err then
                    log:error("on_delete stage returned error", {
                        upload_id = upload.uuid,
                        stage = i,
                        func = func_id,
                        error = call_err,
                    })
                end
            end
        end
    end
end

function upload_lib.upload_file(user_id: string, file_data: string | stream.Stream, filename: string, size: number, mime_type: string?, storage_id: string?, metadata)
    local upload_uuid = generate_upload_id()

    local storage, err = resources.get_storage(storage_id)
    if err then
        return nil, err
    end

    local ext = get_file_extension(filename)
    local storage_path = upload_uuid
    if ext and ext ~= "" then
        storage_path = storage_path .. "." .. ext
    end

    metadata = metadata or {}
    metadata.filename = filename

    if not mime_type or mime_type == "" or mime_type == "application/octet-stream" then
        mime_type = get_mime_type_from_extension(filename)
    end

    local type_id, type_err = determine_upload_type(mime_type, filename)
    if not type_id then
        return nil, type_err
    end

    local success
    success, err = storage:writefile(storage_path, file_data)
    if not success then
        return nil, "Failed to write file: " .. err
    end

    local upload
    upload, err = upload_repo.create(
        upload_uuid,
        user_id,
        size,
        mime_type,
        resources.get_storage_id(storage_id),
        storage_path,
        type_id,
        metadata
    )

    if err then
        pcall(function() storage:remove(storage_path) end)
        return nil, "Failed to create upload record: " .. err
    end

    publish_to_queue(upload_uuid)

    return upload
end

function upload_lib.update_status(uuid, status, error_details)
    return upload_repo.update_status(uuid, status, error_details)
end

function upload_lib.update_metadata(uuid, metadata)
    return upload_repo.update_metadata(uuid, metadata)
end

function upload_lib.update_type_id(uuid, type_id)
    return upload_repo.update_type_id(uuid, type_id)
end

function upload_lib.get_upload(uuid)
    return upload_repo.get(uuid)
end

function upload_lib.list_by_user(user_id, limit, offset)
    return upload_repo.list_by_user(user_id, limit, offset)
end

function upload_lib.list_by_status(status, limit, offset)
    return upload_repo.list_by_status(status, limit, offset)
end

function upload_lib.list_by_type(type_id, limit, offset)
    return upload_repo.list_by_type(type_id, limit, offset)
end

function upload_lib.delete_upload(uuid)
    local upload, err = upload_repo.get(uuid)
    if err then
        return nil, err
    end

    invoke_on_delete(upload)

    content_repo.delete_by_upload(uuid)

    local storage, storage_err = resources.get_storage(tostring(upload.storage_id))
    if storage_err then
        log:error("failed to get storage for cleanup", { upload_id = uuid, error = storage_err })
    else
        pcall(function() storage:remove(tostring(upload.storage_path)) end)
    end

    return upload_repo.delete(uuid)
end

function upload_lib.generate_presigned_url(user_id, filename, size, mime_type, expires_in, metadata)
    if not user_id or user_id == "" then
        return nil, "Invalid user ID"
    end

    if not filename or filename == "" then
        return nil, "Invalid filename"
    end

    if not size or type(size) ~= "number" or size <= 0 then
        return nil, "Invalid file size"
    end

    mime_type = mime_type or "application/octet-stream"
    expires_in = expires_in or 900
    metadata = metadata or {}

    local id = generate_upload_id()
    if not id then
        return nil, "Failed to generate upload ID"
    end

    local sanitized_filename = filename:gsub("[^%w%.%-_]", "_")
    local object_key = user_id .. "/" .. id .. "/" .. sanitized_filename

    local s3, err = resources.get_s3()
    if err then
        return nil, err
    end

    local presigned_url
    presigned_url, err = s3:presigned_put_url(object_key, {
        expires_in = expires_in,
        content_type = mime_type,
        metadata = {
            user_id = user_id,
            original_name = filename,
            upload_id = id,
        },
    })
    s3:release()

    if err then
        return nil, "Failed to generate presigned URL: " .. tostring(err)
    end

    metadata.filename = filename
    metadata.upload_method = "direct_s3"

    local type_id, type_err = determine_upload_type(mime_type, filename)
    if not type_id then
        return nil, type_err
    end

    local _, create_err = upload_repo.create(
        id,
        user_id,
        size,
        mime_type,
        resources.get_s3_id(),
        object_key,
        type_id,
        metadata,
        "pending"
    )

    if create_err then
        return nil, "Failed to create upload record: " .. tostring(create_err)
    end

    local now = time.now()
    local duration = time.parse_duration(expires_in .. "s")
    local expires_at = now:add(duration)

    return {
        url = presigned_url,
        upload_id = id,
        object_key = object_key,
        expires_at = expires_at:unix(),
    }
end

function upload_lib.complete_presigned_url(user_id, upload_id, etag, metadata_updates)
    local upload, err = upload_repo.complete_s3_upload(
        user_id,
        upload_id,
        etag,
        nil,
        metadata_updates
    )

    if err then
        return nil, "Failed to update upload record: " .. err
    end

    publish_to_queue(upload_id)

    return upload
end

return upload_lib
