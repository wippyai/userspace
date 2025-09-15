local fs = require("fs")
local uuid = require("uuid")
local cloudstorage = require("cloudstorage")
local json = require("json")
local env = require("env")

local upload_repo = require("upload_repo")
local upload_type = require("upload_type")
local upload_lib = {}

local UPLOAD_PROCESS = "upload_pipeline"
local UPLOAD_TOPIC = "process_upload"

-- MIME type mapping table for common file extensions (todo: replace with proper module)
local MIME_TYPES = {
    -- Text formats
    ["txt"] = "text/plain",
    ["html"] = "text/html",
    ["htm"] = "text/html",
    ["css"] = "text/css",
    ["csv"] = "text/csv",
    ["xml"] = "application/xml",
    ["md"] = "text/markdown",

    -- Document formats
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

    -- Image formats
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

    -- Audio formats
    ["mp3"] = "audio/mpeg",
    ["wav"] = "audio/wav",
    ["ogg"] = "audio/ogg",
    ["flac"] = "audio/flac",
    ["aac"] = "audio/aac",
    ["m4a"] = "audio/mp4",

    -- Video formats
    ["mp4"] = "video/mp4",
    ["avi"] = "video/x-msvideo",
    ["mov"] = "video/quicktime",
    ["wmv"] = "video/x-ms-wmv",
    ["mkv"] = "video/x-matroska",
    ["webm"] = "video/webm",
    ["flv"] = "video/x-flv",

    -- Archive formats
    ["zip"] = "application/zip",
    ["rar"] = "application/x-rar-compressed",
    ["7z"] = "application/x-7z-compressed",
    ["tar"] = "application/x-tar",
    ["gz"] = "application/gzip",

    -- Programming and data formats
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

    -- Font formats
    ["ttf"] = "font/ttf",
    ["otf"] = "font/otf",
    ["woff"] = "font/woff",
    ["woff2"] = "font/woff2",

    -- Other formats
    ["exe"] = "application/octet-stream",
    ["bin"] = "application/octet-stream",
    ["dmg"] = "application/x-apple-diskimage",
    ["iso"] = "application/x-iso9660-image"
}

-- Generate a unique upload ID
local function generate_upload_id()
    return uuid.v4()
end

-- Extract file extension from filename
local function get_file_extension(filename)
    return filename:match("%.([^%.]+)$") or ""
end

-- Get MIME type from file extension
local function get_mime_type_from_extension(filename)
    local ext = get_file_extension(filename):lower()

    -- Return the MIME type if found in the mapping table
    if ext and MIME_TYPES[ext] then
        return MIME_TYPES[ext]
    end

    -- Default MIME type for unknown extensions
    return "application/octet-stream"
end

-- Determine the upload type from MIME type and extension
local function determine_upload_type(mime_type, filename)
    local ext = get_file_extension(filename)

    -- Try to find a matching upload type
    local type_entry, err = upload_type.find_by_mime_or_ext(mime_type, ext)
    if not type_entry then
        return nil, "Unsupported file type: " .. (err or "unknown error")
    end

    return type_entry.id
end

-- Get the appropriate storage based on storage ID
local function get_storage(storage_id)
    local fs_instance, err = fs.get(storage_id)
    if err then
        return nil, "Failed to get filesystem: " .. err
    end
    return fs_instance, nil, "fs"
end

-- Upload a file to the specified storage and create a record
function upload_lib.upload_file(user_id, file_data, filename, size, mime_type, storage_id, metadata)
    -- Get default storage ID from environment if not specified
    if not storage_id or storage_id == "" then
        storage_id = env.get("UPLOAD_STORAGE_ID")
    end

    -- Generate a unique upload ID
    local upload_uuid = generate_upload_id()

    -- Get the appropriate storage
    local storage, err, actual_storage_id = get_storage(storage_id)
    if err then
        return nil, err
    end

    -- Include file extension in storage path
    local ext = get_file_extension(filename)
    local storage_path = upload_uuid
    if ext and ext ~= "" then
        storage_path = storage_path .. "." .. ext
    end

    local success = false

    -- Initialize metadata or create a new table if it doesn't exist
    metadata = metadata or {}

    -- Add filename to metadata
    metadata.filename = filename

    -- Detect MIME type from extension if not provided or if it's a generic type
    if not mime_type or mime_type == "" or mime_type == "application/octet-stream" then
        mime_type = get_mime_type_from_extension(filename)
    end

    -- Determine upload type
    local type_id, type_err = determine_upload_type(mime_type, filename)
    if not type_id then
        return nil, type_err
    end

    -- Store the file based on storage ID
    if actual_storage_id == "cs" then
        success, err = storage:upload_object(storage_path, file_data)
        if not success then
            return nil, "Failed to upload to cloud storage: " .. err
        end
    else
        -- Write the file directly using the UUID as the filename
        success, err = storage:writefile(storage_path, file_data)
        if not success then
            return nil, "Failed to write file: " .. err
        end
    end

    -- Create the upload record
    local upload, err = upload_repo.create(
        upload_uuid,
        user_id,
        size,
        mime_type,
        storage_id,
        storage_path,
        type_id,
        metadata
    )

    if err then
        -- Try to clean up the stored file if record creation fails
        if actual_storage_id == "cs" then
            pcall(function() storage:delete_objects(storage_path) end)
        else
            pcall(function() storage:remove(storage_path) end)
        end
        return nil, "Failed to create upload record: " .. err
    end

    -- notify our pipeline about new upload to process
    process.send(UPLOAD_PROCESS, UPLOAD_TOPIC, { upload_id = upload_uuid })

    return upload
end

-- Update the status of an upload
function upload_lib.update_status(uuid, status, error_details)
    return upload_repo.update_status(uuid, status, error_details)
end

-- Update the metadata of an upload
function upload_lib.update_metadata(uuid, metadata)
    return upload_repo.update_metadata(uuid, metadata)
end

-- Update the type ID of an upload
function upload_lib.update_type_id(uuid, type_id)
    return upload_repo.update_type_id(uuid, type_id)
end

-- Get an upload by ID
function upload_lib.get_upload(uuid)
    return upload_repo.get(uuid)
end

-- List uploads by user ID
function upload_lib.list_by_user(user_id, limit, offset)
    return upload_repo.list_by_user(user_id, limit, offset)
end

-- List uploads by status
function upload_lib.list_by_status(status, limit, offset)
    return upload_repo.list_by_status(status, limit, offset)
end

-- List uploads by type
function upload_lib.list_by_type(type_id, limit, offset)
    return upload_repo.list_by_type(type_id, limit, offset)
end

-- Delete an upload and its file
function upload_lib.delete_upload(uuid)
    -- Get the upload record
    local upload, err = upload_repo.get(uuid)
    if err then
        return nil, err
    end

    -- Delete the file based on storage type
    local storage, err = get_storage(upload.storage_id)
    if err then
        -- Continue with deletion even if we can't get storage
        print("Warning: Failed to get storage for cleanup: " .. err)
    else
        if upload.storage_type == "cs" then
            pcall(function() storage:delete_objects(upload.storage_path) end)
        else
            pcall(function() storage:remove(upload.storage_path) end)
        end
    end

    -- Delete the record
    return upload_repo.delete(uuid)
end








-- Add this function to your existing upload_lib.lua file

-- Generate a presigned URL for direct upload to S3
-- Parameters:
--   user_id: ID of the user initiating the upload
--   filename: Original filename
--   size: Expected file size in bytes
--   mime_type: MIME type of the file
--   expires_in: Expiration time in seconds (default: 900 seconds = 15 minutes)
--   metadata: Additional metadata to store with the upload record
-- Returns:
--   A table with presigned URL information
function upload_lib.generate_presigned_url(user_id, filename, size, mime_type, expires_in, metadata)
    -- Validate parameters
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
    expires_in = expires_in or 900 -- Default to 15 minutes
    metadata = metadata or {}

    -- Generate a unique upload ID (UUID)
    local uuid = generate_upload_id()
    if not uuid then
        return nil, "Failed to generate upload ID"
    end

    -- Generate a safe S3 object key
    local sanitized_filename = filename:gsub("[^%w%.%-_]", "_")
    local object_key = user_id .. "/" .. uuid .. "/" .. sanitized_filename

    -- Get the S3 storage instance
    local s3, err = cloudstorage.get("app:uploads.s3")
    if err then
        return nil, err
    end

    -- Generate presigned PUT URL
    local presigned_url, err = s3:presigned_put_url(object_key, {
        expires_in = expires_in,
        content_type = mime_type,
        metadata = {
            user_id = user_id,
            original_name = filename,
            upload_id = uuid
        }
    })
    s3:release()

    if err then
        return nil, "Failed to generate presigned URL: " .. tostring(err)
    end

    -- Add original file name and upload status to metadata
    metadata.filename = filename
    metadata.upload_method = "direct_s3"

    -- Determine upload type
    local type_id, type_err = determine_upload_type(mime_type, filename)
    if not type_id then
        return nil, type_err
    end

    -- Create upload record using the existing upload_repo.create method
    local upload_repo = require("upload_repo")
    local record, err = upload_repo.create(
        uuid,                -- uuid
        user_id,             -- user_id
        size,                -- size
        mime_type,           -- mime_type
        "uploads.s3",
        object_key,          -- storage_path (S3 object key)
        type_id,
        metadata,            -- metadata
        "pending"
    )

    if err then
        return nil, "Failed to create upload record: " .. tostring(err)
    end

    -- Calculate expiration time for client reference
    local now = require("time").now()
    local duration = require("time").parse_duration(expires_in .. "s")
    local expires_at = now:add(duration)

    -- Return presigned URL information
    return {
        url = presigned_url,
        upload_id = uuid,
        object_key = object_key,
        expires_at = expires_at:unix()
    }
end

function upload_lib.complete_presigned_url(user_id, upload_id, etag, metadata_updates)
    -- Verify and complete the upload
    local upload, err = upload_repo.complete_s3_upload(
        user_id,
        upload_id,
        etag,
        key,
        metadata_updates
    )

    if err then
        return nil, "Failed to update upload record: " .. err
    end

    -- notify our pipeline about new upload to process
    process.send(UPLOAD_PROCESS, UPLOAD_TOPIC, { upload_id = upload_id })

    return upload, nil
end

return upload_lib