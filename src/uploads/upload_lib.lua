local uuid = require("uuid")
local json = require("json")
local time = require("time")
local queue = require("queue")
local funcs = require("funcs")
local security = require("security")
local logger = require("logger")

local upload_repo = require("upload_repo")
local upload_type = require("upload_type")
local pipeline_lib = require("pipeline_lib")
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

local UNSUPPORTED_FORMAT = "unsupported_format"
local HTTP_UNSUPPORTED_MEDIA_TYPE = 415

local function determine_upload_type(mime_type, filename)
    local ext = get_file_extension(filename)
    local type_entry, err = upload_type.find_by_mime_or_ext(mime_type, ext)
    if type_entry then
        return type_entry.id
    end

    if err == upload_type.NO_MATCH then
        local shown_ext = ext ~= "" and ("." .. ext) or "no extension"
        return nil, errors.new({
            message = "Unsupported file type: " .. tostring(mime_type or "unknown mime") .. " (" .. shown_ext .. ")",
            kind = errors.INVALID,
            retryable = false,
            details = { code = UNSUPPORTED_FORMAT, mime_type = mime_type, extension = ext },
        })
    end

    return nil, errors.new({
        message = "Failed to determine upload type: " .. tostring(err or "unknown error"),
        kind = errors.INTERNAL,
        retryable = true,
    })
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

local function write_upload_bytes(resolved_storage_id, user_id, upload_uuid, filename, mime_type, file_data)
    if resources.is_cloud_storage(resolved_storage_id) then
        local sanitized_filename = filename:gsub("[^%w%.%-_]", "_")
        local storage_path = user_id .. "/" .. upload_uuid .. "/" .. sanitized_filename

        local s3, err = resources.get_s3(resolved_storage_id)
        if err then
            return nil, err
        end

        local ok, write_err = s3:upload_object(storage_path, file_data, {
            content_type = mime_type,
        })
        s3:release()

        if not ok then
            return nil, "Failed to write file: " .. tostring(write_err)
        end

        return storage_path
    end

    local storage, err = resources.get_storage(resolved_storage_id)
    if err then
        return nil, err
    end

    local ext = get_file_extension(filename)
    local storage_path = upload_uuid
    if ext and ext ~= "" then
        storage_path = storage_path .. "." .. ext
    end

    local success, write_err = storage:writefile(storage_path, file_data)
    if not success then
        return nil, "Failed to write file: " .. tostring(write_err)
    end

    return storage_path
end

local function remove_upload_bytes(resolved_storage_id, storage_path)
    if resources.is_cloud_storage(resolved_storage_id) then
        local s3, err = resources.get_s3(resolved_storage_id)
        if err then
            return nil, err
        end
        local _, del_err = s3:delete_objects({ storage_path })
        s3:release()
        if del_err then
            return nil, tostring(del_err)
        end
        return true
    end

    local storage, err = resources.get_storage(resolved_storage_id)
    if err then
        return nil, err
    end
    pcall(function() storage:remove(storage_path) end)
    return true
end

function upload_lib.upload_file(user_id: string, file_data: string | stream.Stream, filename: string, size: number, mime_type: string?, storage_id: string?, metadata: any?)
    local upload_uuid = generate_upload_id()
    local resolved_storage_id = resources.get_storage_id(storage_id)

    metadata = metadata or {}
    metadata.filename = filename

    if not mime_type or mime_type == "" or mime_type == "application/octet-stream" then
        mime_type = get_mime_type_from_extension(filename)
    end

    local type_id, type_err = determine_upload_type(mime_type, filename)
    if not type_id then
        return nil, type_err
    end

    local storage_path, write_err = write_upload_bytes(
        resolved_storage_id, user_id, upload_uuid, filename, mime_type, file_data
    )
    if not storage_path then
        return nil, write_err
    end

    local upload, err = upload_repo.create(
        upload_uuid,
        user_id,
        size,
        mime_type,
        resolved_storage_id,
        storage_path,
        type_id,
        metadata
    )

    if err then
        pcall(function() remove_upload_bytes(resolved_storage_id, storage_path) end)
        return nil, "Failed to create upload record: " .. err
    end

    publish_to_queue(upload_uuid)

    pipeline_lib.invoke_upload_token(upload, pipeline_lib.STATUS.UPLOADED)

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

    local _, cleanup_err = remove_upload_bytes(tostring(upload.storage_id), tostring(upload.storage_path))
    if cleanup_err then
        log:error("failed to remove upload bytes", { upload_id = uuid, error = cleanup_err })
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

    pipeline_lib.invoke_upload_token(upload, pipeline_lib.STATUS.UPLOADED)

    return upload
end

local MULTIPART_ID_KEY = "__multipart_upload_id"
local MULTIPART_MIN_PART_SIZE = 5 * 1024 * 1024
local MULTIPART_RECOMMENDED_PART_SIZE = 64 * 1024 * 1024
local MULTIPART_MAX_PARTS = 10000

local function get_multipart_upload(user_id, upload_id)
    if not user_id or user_id == "" then
        return nil, "Invalid user ID"
    end

    if not upload_id or upload_id == "" then
        return nil, "Invalid upload ID"
    end

    local upload, err = upload_repo.get(upload_id)
    if err then
        return nil, "Failed to retrieve upload record: " .. tostring(err)
    end

    if upload.user_id ~= user_id then
        return nil, "Access denied: upload belongs to another user"
    end

    if not upload.metadata or not upload.metadata[MULTIPART_ID_KEY] then
        return nil, "Upload is not a multipart upload"
    end

    return upload
end

function upload_lib.create_multipart_upload(user_id, filename, size, mime_type, metadata)
    if not user_id or user_id == "" then
        return nil, "Invalid user ID"
    end

    if not filename or filename == "" then
        return nil, "Invalid filename"
    end

    if not size or type(size) ~= "number" or size <= 0 then
        return nil, "Invalid file size"
    end

    metadata = metadata or {}

    if not mime_type or mime_type == "" or mime_type == "application/octet-stream" then
        mime_type = get_mime_type_from_extension(filename)
    end

    -- Fail fast on unsupported types before creating any provider-side state.
    local type_id, type_err = determine_upload_type(mime_type, filename)
    if not type_id then
        return nil, type_err
    end

    local id = generate_upload_id()
    local sanitized_filename = filename:gsub("[^%w%.%-_]", "_")
    local object_key = user_id .. "/" .. id .. "/" .. sanitized_filename

    local s3, err = resources.get_s3()
    if err then
        return nil, err
    end

    local created
    created, err = s3:create_multipart_upload(object_key, {
        content_type = mime_type,
        metadata = {
            user_id = user_id,
            original_name = filename,
            upload_id = id,
        },
    })
    s3:release()

    if err then
        return nil, "Failed to create multipart upload: " .. tostring(err)
    end

    metadata.filename = filename
    metadata.upload_method = "multipart_s3"
    metadata[MULTIPART_ID_KEY] = created.upload_id

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
        -- Don't leave an orphaned multipart upload accruing stored parts.
        local s3c, s3c_err = resources.get_s3()
        if not s3c_err then
            pcall(function() s3c:abort_multipart_upload(object_key, created.upload_id) end)
            s3c:release()
        end
        return nil, "Failed to create upload record: " .. tostring(create_err)
    end

    return {
        upload_id = id,
        object_key = object_key,
        part_size = MULTIPART_RECOMMENDED_PART_SIZE,
        min_part_size = MULTIPART_MIN_PART_SIZE,
        max_parts = MULTIPART_MAX_PARTS,
    }
end

function upload_lib.multipart_part_urls(user_id, upload_id, part_numbers: {number}, expires_in: number?)
    local upload, err = get_multipart_upload(user_id, upload_id)
    if err then
        return nil, err
    end

    if upload.status ~= "pending" then
        return nil, "Upload is in invalid state: " .. tostring(upload.status)
    end

    if not part_numbers or type(part_numbers) ~= "table" or #part_numbers == 0 then
        return nil, "At least one part number is required"
    end

    expires_in = expires_in or 900

    local s3, s3_err = resources.get_s3(tostring(upload.storage_id))
    if s3_err then
        return nil, s3_err
    end

    local urls
    urls, err = s3:presigned_part_urls(
        tostring(upload.storage_path),
        tostring(upload.metadata[MULTIPART_ID_KEY]),
        {
            parts = part_numbers,
            expiration = expires_in,
        }
    )
    s3:release()

    if err then
        return nil, "Failed to generate part URLs: " .. tostring(err)
    end

    return urls
end

function upload_lib.complete_multipart_upload(user_id, upload_id, parts: {{part_number: number, etag: string}}, metadata_updates: any?)
    local upload, err = get_multipart_upload(user_id, upload_id)
    if err then
        return nil, err
    end

    if upload.status ~= "pending" then
        if upload.status == "uploaded" then
            -- Already completed; idempotent like complete_presigned_url.
            return upload
        end
        return nil, "Upload is in invalid state: " .. tostring(upload.status)
    end

    if not parts or type(parts) ~= "table" or #parts == 0 then
        return nil, "At least one completed part is required"
    end

    local object_key = tostring(upload.storage_path)

    local s3, s3_err = resources.get_s3(tostring(upload.storage_id))
    if s3_err then
        return nil, s3_err
    end

    local _, complete_err = s3:complete_multipart_upload(
        object_key,
        tostring(upload.metadata[MULTIPART_ID_KEY]),
        parts
    )

    if complete_err then
        s3:release()
        return nil, "Failed to complete multipart upload: " .. tostring(complete_err)
    end

    -- Reconcile the declared size with what the storage actually holds —
    -- multipart is the one path where the backend can tell us for sure.
    local head, head_err = s3:head_object(object_key)
    s3:release()

    local metadata = upload.metadata or {}
    metadata[MULTIPART_ID_KEY] = nil
    if metadata_updates then
        for k, v in pairs(metadata_updates) do
            metadata[k] = v
        end
    end

    local _, meta_err = upload_repo.update_metadata(upload_id, metadata)
    if meta_err then
        log:error("failed to update multipart metadata", { upload_id = upload_id, error = meta_err })
    end

    if head_err or not head then
        log:warn("failed to stat completed multipart object; keeping declared size", {
            upload_id = upload_id,
            error = tostring(head_err),
        })
    elseif head.size and head.size > 0 and head.size ~= upload.size then
        local _, size_err = upload_repo.update_size(upload_id, head.size)
        if size_err then
            log:warn("failed to reconcile multipart size", { upload_id = upload_id, error = size_err })
        else
            upload.size = head.size
        end
    end

    local updated, status_err = upload_repo.update_status(upload_id, "uploaded")
    if status_err then
        return nil, "Failed to update upload record: " .. tostring(status_err)
    end

    publish_to_queue(upload_id)

    upload.status = "uploaded"
    upload.updated_at = updated.updated_at
    upload.metadata = metadata

    pipeline_lib.invoke_upload_token(upload, pipeline_lib.STATUS.UPLOADED)

    return upload
end

function upload_lib.abort_multipart_upload(user_id, upload_id)
    local upload, err = get_multipart_upload(user_id, upload_id)
    if err then
        return nil, err
    end

    if upload.status ~= "pending" then
        return nil, "Upload is in invalid state: " .. tostring(upload.status)
    end

    local s3, s3_err = resources.get_s3(tostring(upload.storage_id))
    if s3_err then
        return nil, s3_err
    end

    local _, abort_err = s3:abort_multipart_upload(
        tostring(upload.storage_path),
        tostring(upload.metadata[MULTIPART_ID_KEY])
    )
    s3:release()

    if abort_err then
        -- An already-expired/aborted provider upload is fine — the goal is
        -- to stop tracking it; anything else is only worth a log line.
        log:warn("abort multipart upload reported an error", {
            upload_id = upload_id,
            error = tostring(abort_err),
        })
    end

    return upload_repo.delete(upload_id)
end

upload_lib.UNSUPPORTED_FORMAT = UNSUPPORTED_FORMAT

function upload_lib.error_code(err)
    if type(err) ~= "userdata" then
        return nil
    end
    local ok, details = pcall(function()
        return err:details()
    end)
    if not ok or type(details) ~= "table" then
        return nil
    end
    return details.code
end

function upload_lib.failure_response(err, fallback_error)
    if upload_lib.error_code(err) == UNSUPPORTED_FORMAT then
        return HTTP_UNSUPPORTED_MEDIA_TYPE, {
            success = false,
            code = UNSUPPORTED_FORMAT,
            retryable = false,
            error = "This file type isn't supported.",
            details = tostring(err),
        }
    end
    return 500, {
        success = false,
        error = fallback_error,
        details = tostring(err),
    }
end

return upload_lib
