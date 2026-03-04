local json = require("json")
local time = require("time")

local resources = require("uploads_resources")

local upload_repo = {}

-- Get current Unix timestamp (seconds since epoch)
local function current_timestamp()
    return time.now():unix()
end

-- Create a new upload record
function upload_repo.create(uuid, user_id, size, mime_type, storage_id, storage_path, type_id, metadata, status)
    if status == nil then status = "uploaded" end

    if not uuid or uuid == "" then
        return nil, "Upload ID is required"
    end

    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    if not size or size <= 0 then
        return nil, "Valid file size is required"
    end

    if not mime_type or mime_type == "" then
        return nil, "MIME type is required"
    end

    if not storage_id or storage_id == "" then
        return nil, "Storage ID is required"
    end

    if not storage_path or storage_path == "" then
        return nil, "Storage path is required"
    end

    if not type_id or type_id == "" then
        return nil, "Type ID is required"
    end

    -- If metadata doesn't exist, initialize as empty table
    metadata = metadata or {}

    -- Convert metadata to JSON if it's a table
    local metadata_json = nil
    if type(metadata) == "table" then
        local encoded, err = json.encode(metadata)
        if err then
            return nil, "Failed to encode metadata: " .. err
        end
        metadata_json = encoded
    else
        metadata_json = metadata
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the INSERT query
    local query = sql.builder.insert("uploads")
        :set_map({
            uuid = uuid,
            user_id = user_id,
            size = sql.as.int(size),
            mime_type = mime_type,
            status = status,
            storage_id = storage_id,
            storage_path = storage_path,
            type_id = type_id,
            created_at = now,
            updated_at = now,
            error_details = sql.as.null(),
            metadata = metadata_json
        })

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to create upload record: " .. err
    end

    return {
        uuid = uuid,
        user_id = user_id,
        size = size,
        mime_type = mime_type,
        status = status,
        storage_id = storage_id,
        storage_path = storage_path,
        type_id = type_id,
        created_at = now,
        updated_at = now,
        metadata = metadata
    }
end

-- Get an upload by ID
function upload_repo.get(uuid)
    if not uuid or uuid == "" then
        return nil, "Upload ID is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    -- Build the SELECT query
    local query = sql.builder.select(
            "uuid", "user_id", "size", "mime_type",
            "status", "storage_id", "storage_path", "type_id", "created_at",
            "updated_at", "error_details", "metadata"
        )
        :from("uploads")
        :where("uuid = ?", uuid)
        :limit(1)

    -- Execute the query
    local executor = query:run_with(db)
    local uploads, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to get upload: " .. err
    end

    if #uploads == 0 then
        return nil, "Upload not found"
    end

    local upload = uploads[1]

    -- Parse metadata JSON if it exists
    if upload.metadata and upload.metadata ~= "" then
        local decoded, err = json.decode(tostring(upload.metadata))
        if not err then
            upload.metadata = decoded
        else
            -- Fallback to empty table if JSON parsing fails
            upload.metadata = {}
        end
    else
        upload.metadata = {}
    end

    return upload
end

-- Update upload status
function upload_repo.update_status(uuid, status, error_details)
    if not uuid or uuid == "" then
        return nil, "Upload ID is required"
    end

    if not status or status == "" then
        return nil, "Status is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the UPDATE query
    local query = sql.builder.update("uploads")
        :set("status", status)
        :set("updated_at", now)

    -- Add error_details if provided
    if error_details then
        query = query:set("error_details", error_details)
    end

    -- Add WHERE clause
    query = query:where("uuid = ?", uuid)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to update upload status: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Upload not found"
    end

    return {
        uuid = uuid,
        status = status,
        updated_at = now,
        updated = true
    }
end

-- Update upload storage
function upload_repo.update_storage(uuid, storage_id, storage_path)
    if not uuid or uuid == "" then
        return nil, "Upload ID is required"
    end

    if not storage_id or storage_id == "" then
        return nil, "Storage ID is required"
    end

    if not storage_path or storage_path == "" then
        return nil, "Storage Path is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the UPDATE query
    local query = sql.builder.update("uploads")
        :set("storage_id", storage_id)
        :set("storage_path", storage_path)
        :set("updated_at", now)

    -- Add error_details if provided
    if error_details then
        query = query:set("error_details", error_details)
    end

    -- Add WHERE clause
    query = query:where("uuid = ?", uuid)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to update upload storage: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Upload not found"
    end

    return {
        uuid = uuid,
        storage_id = storage_id,
        storage_path = storage_path,
        updated_at = now,
        updated = true
    }
end

-- Update upload metadata
function upload_repo.update_metadata(uuid, metadata)
    if not uuid or uuid == "" then
        return nil, "Upload ID is required"
    end

    if not metadata then
        return nil, "Metadata is required"
    end

    -- Convert metadata to JSON if it's a table
    local metadata_json = nil
    if type(metadata) == "table" then
        local encoded, err = json.encode(metadata)
        if err then
            return nil, "Failed to encode metadata: " .. err
        end
        metadata_json = encoded
    else
        metadata_json = metadata
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the UPDATE query
    local query = sql.builder.update("uploads")
        :set("metadata", metadata_json)
        :set("updated_at", now)
        :where("uuid = ?", uuid)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to update upload metadata: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Upload not found"
    end

    return {
        uuid = uuid,
        updated_at = now,
        metadata = metadata,
        updated = true
    }
end

-- Update upload type ID
function upload_repo.update_type_id(uuid, type_id)
    if not uuid or uuid == "" then
        return nil, "Upload ID is required"
    end

    if not type_id or type_id == "" then
        return nil, "Type ID is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the UPDATE query
    local query = sql.builder.update("uploads")
        :set("type_id", type_id)
        :set("updated_at", now)
        :where("uuid = ?", uuid)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to update upload type: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Upload not found"
    end

    return {
        uuid = uuid,
        type_id = type_id,
        updated_at = now,
        updated = true
    }
end

-- List uploads by user ID
function upload_repo.list_by_user(user_id, limit, offset)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    limit = limit or 100
    offset = offset or 0

    -- Build the SELECT query
    local query = sql.builder.select(
            "uuid", "user_id", "size", "mime_type",
            "status", "storage_id", "storage_path", "type_id", "created_at",
            "updated_at", "error_details", "metadata"
        )
        :from("uploads")
        :where("user_id = ?", user_id)
        :order_by("created_at DESC")
        :limit(limit)
        :offset(offset)

    -- Execute the query
    local executor = query:run_with(db)
    local uploads, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to list uploads: " .. err
    end

    -- Parse metadata JSON for each upload
    for i, upload in ipairs(uploads) do
        if upload.metadata and upload.metadata ~= "" then
            local decoded, err = json.decode(tostring(upload.metadata))
            if not err then
                upload.metadata = decoded
            else
                -- Fallback to empty table if JSON parsing fails
                upload.metadata = {}
            end
        else
            upload.metadata = {}
        end
    end

    return uploads
end

-- List uploads by status
function upload_repo.list_by_status(status, limit, offset)
    if not status or status == "" then
        return nil, "Status is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    limit = limit or 100
    offset = offset or 0

    -- Build the SELECT query
    local query = sql.builder.select(
            "uuid", "user_id", "size", "mime_type",
            "status", "storage_id", "storage_path", "type_id", "created_at",
            "updated_at", "error_details", "metadata"
        )
        :from("uploads")
        :where("status = ?", status)
        :order_by("created_at DESC")
        :limit(limit)
        :offset(offset)

    -- Execute the query
    local executor = query:run_with(db)
    local uploads, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to list uploads by status: " .. err
    end

    -- Parse metadata JSON for each upload
    for i, upload in ipairs(uploads) do
        if upload.metadata and upload.metadata ~= "" then
            local decoded, err = json.decode(tostring(upload.metadata))
            if not err then
                upload.metadata = decoded
            else
                -- Fallback to empty table if JSON parsing fails
                upload.metadata = {}
            end
        else
            upload.metadata = {}
        end
    end

    return uploads
end

-- List uploads by type ID
function upload_repo.list_by_type(type_id, limit, offset)
    if not type_id or type_id == "" then
        return nil, "Type ID is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    limit = limit or 100
    offset = offset or 0

    -- Build the SELECT query
    local query = sql.builder.select(
            "uuid", "user_id", "size", "mime_type",
            "status", "storage_id", "storage_path", "type_id", "created_at",
            "updated_at", "error_details", "metadata"
        )
        :from("uploads")
        :where("type_id = ?", type_id)
        :order_by("created_at DESC")
        :limit(limit)
        :offset(offset)

    -- Execute the query
    local executor = query:run_with(db)
    local uploads, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to list uploads by type: " .. err
    end

    -- Parse metadata JSON for each upload
    for i, upload in ipairs(uploads) do
        if upload.metadata and upload.metadata ~= "" then
            local decoded, err = json.decode(tostring(upload.metadata))
            if not err then
                upload.metadata = decoded
            else
                -- Fallback to empty table if JSON parsing fails
                upload.metadata = {}
            end
        else
            upload.metadata = {}
        end
    end

    return uploads
end

-- Delete an upload
function upload_repo.delete(uuid)
    if not uuid or uuid == "" then
        return nil, "Upload ID is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    -- Build the DELETE query
    local query = sql.builder.delete("uploads")
        :where("uuid = ?", uuid)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to delete upload: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Upload not found"
    end

    return { deleted = true }
end

-- Count total uploads for a user
function upload_repo.count_by_user(user_id)
    if not user_id or user_id == "" then
        return nil, "User ID is required"
    end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    -- Build the COUNT query
    local query = sql.builder.select("COUNT(*) as count")
        :from("uploads")
        :where("user_id = ?", user_id)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to count uploads: " .. err
    end

    return result[1].count
end

-- Extension to upload_repo.lua
-- Add this function to the existing upload_repo module

-- Find next batch of processable uploads
function upload_repo.get_pending_uploads(limit, offset)
    if not limit then limit = 20 end
    if not offset then offset = 0 end

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    -- Simple, efficient query for uploads that need processing
    local query = sql.builder.select(
            "uuid", "user_id", "size", "mime_type",
            "status", "storage_id", "storage_path", "type_id", "created_at",
            "updated_at", "error_details", "metadata"
        )
        :from("uploads")
        :where(sql.builder.or_({
            sql.builder.eq({ status = "uploaded" }),
            sql.builder.eq({ status = "queued" })
        }))
        :order_by("created_at ASC")
        :limit(limit)
        :offset(offset)

    -- Execute the query
    local executor = query:run_with(db)
    local uploads, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to list pending uploads: " .. err
    end

    -- Process metadata like in the original code
    for i, upload in ipairs(uploads) do
        if upload.metadata and upload.metadata ~= "" then
            local decoded, err = json.decode(tostring(upload.metadata))
            if not err then
                upload.metadata = decoded
            else
                upload.metadata = {}
            end
        else
            upload.metadata = {}
        end
    end

    return uploads
end

-- Complete an S3 direct upload
-- Parameters:
--   user_id: ID of the user who initiated the upload
--   upload_id: The UUID of the pending upload
--   etag: Optional ETag from S3 response
--   key: Optional S3 object key if different from expected
--   metadata_updates: Optional metadata updates
-- Returns:
--   The completed upload record
function upload_repo.complete_s3_upload(user_id, upload_id, etag, key, metadata_updates)
    -- Validate parameters
    if not user_id or user_id == "" then
        return nil, "Invalid user ID"
    end
    -- todo: remove this function
    if not upload_id or upload_id == "" then
        return nil, "Invalid upload ID"
    end

    metadata_updates = metadata_updates or {}

    -- Get the pending upload record
    local upload, err = upload_repo.get(upload_id)
    if err then
        return nil, "Failed to retrieve upload record: " .. tostring(err)
    end

    if not upload then
        return nil, "Upload record not found for ID: " .. upload_id
    end

    -- Verify the upload belongs to the user
    if upload.user_id ~= user_id then
        return nil, "Access denied: upload belongs to another user"
    end

    -- Verify upload is in pending state
    if upload.status ~= "pending" then
        if upload.status == "uploaded" then
            -- Already completed, just return the record
            return upload
        else
            return nil, "Upload is in invalid state: " .. tostring(upload.status)
        end
    end

    -- Update the record
    local updated, err = upload_repo.update_status(upload_id, "uploaded", nil)
    if err then
        return nil, "Failed to update upload record: " .. tostring(err)
    end

    return updated
end

function upload_repo.list_with_filters(options)
    options = options or {}

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select(
            "uuid", "user_id", "size", "mime_type", "status",
            "storage_id", "storage_path", "type_id", "created_at",
            "updated_at", "error_details", "metadata"
        )
        :from("uploads")

    if options.user_id then
        query = query:where("user_id = ?", options.user_id)
    end

    if options.after_id then
        query = query:where("uuid > ?", options.after_id)
    end

    if options.filters and options.filters.content_types and #options.filters.content_types > 0 then
        local content_conditions = {}
        for _, content_type in ipairs(options.filters.content_types) do
            if string.find(tostring(content_type), "*") then
                local pattern = string.gsub(tostring(content_type), "%*", "%%")
                query = query:where("mime_type LIKE ?", pattern)
            else
                table.insert(content_conditions, sql.builder.eq({ mime_type = content_type }))
            end
        end

        if #content_conditions > 0 then
            if #content_conditions == 1 then
                query = query:where(content_conditions[1])
            else
                query = query:where(sql.builder.or_(content_conditions))
            end
        end
    end

    if options.filters and options.filters.created_after then
        query = query:where("created_at >= ?", options.filters.created_after)
    end

    if options.filters and options.filters.created_before then
        query = query:where("created_at <= ?", options.filters.created_before)
    end

    local sort_column = "created_at"
    if options.sort == "size" then
        sort_column = "size"
    end

    local order = "DESC"
    if options.sort_order == "asc" then
        order = "ASC"
    end

    query = query:order_by(sort_column .. " " .. order .. ", uuid ASC")

    if options.limit then
        query = query:limit(options.limit)
    end

    local executor = query:run_with(db)
    local uploads, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to list uploads: " .. err
    end

    for i, upload in ipairs(uploads) do
        if upload.metadata and upload.metadata ~= "" then
            local decoded, parse_err = json.decode(tostring(upload.metadata))
            if not parse_err then
                upload.metadata = decoded
            else
                upload.metadata = {}
            end
        else
            upload.metadata = {}
        end
    end

    return uploads
end

function upload_repo.count_with_filters(options)
    options = options or {}

    local db, err = resources.get_db()
    if err then
        return nil, err
    end

    local query = sql.builder.select("COUNT(*) as count")
        :from("uploads")

    if options.user_id then
        query = query:where("user_id = ?", options.user_id)
    end

    if options.filters and options.filters.content_types and #options.filters.content_types > 0 then
        local content_conditions = {}
        for _, content_type in ipairs(options.filters.content_types) do
            if string.find(tostring(content_type), "*") then
                local pattern = string.gsub(tostring(content_type), "%*", "%%")
                query = query:where("mime_type LIKE ?", pattern)
            else
                table.insert(content_conditions, sql.builder.eq({ mime_type = content_type }))
            end
        end

        if #content_conditions > 0 then
            if #content_conditions == 1 then
                query = query:where(content_conditions[1])
            else
                query = query:where(sql.builder.or_(content_conditions))
            end
        end
    end

    if options.filters and options.filters.created_after then
        query = query:where("created_at >= ?", options.filters.created_after)
    end

    if options.filters and options.filters.created_before then
        query = query:where("created_at <= ?", options.filters.created_before)
    end

    local executor = query:run_with(db)
    local result, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to count uploads: " .. err
    end

    return result[1].count
end

return upload_repo
