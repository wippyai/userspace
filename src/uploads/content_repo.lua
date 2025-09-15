local sql = require("sql")
local json = require("json")
local time = require("time")
local uuid = require("uuid")

-- Hardcoded database resource name
local DB_RESOURCE = "app:db"

local content_repo = {}

-- Get a database connection
local function get_db()
    local db, err = sql.get(DB_RESOURCE)
    if err then
        return nil, "Failed to connect to database: " .. err
    end
    return db
end

-- Get current Unix timestamp (seconds since epoch)
local function current_timestamp()
    return time.now():unix()
end

-- Create a new content record
function content_repo.create(upload_id, mime_type, content, metadata)
    if not upload_id or upload_id == "" then
        return nil, "Upload ID is required"
    end

    if not mime_type or mime_type == "" then
        return nil, "MIME type is required"
    end

    -- Generate a unique content ID
    local content_id = uuid.v4()

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

    local db, err = get_db()
    if err then
        return nil, err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the INSERT query
    local query = sql.builder.insert("upload_content")
        :set_map({
            content_id = content_id,
            upload_id = upload_id,
            mime_type = mime_type,
            content = content,
            metadata = metadata_json,
            created_at = now,
            updated_at = now
        })

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to create content record: " .. err
    end

    return {
        content_id = content_id,
        upload_id = upload_id,
        mime_type = mime_type,
        created_at = now,
        updated_at = now,
        metadata = metadata
    }
end

-- Get content by ID
function content_repo.get(content_id)
    if not content_id or content_id == "" then
        return nil, "Content ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Build the SELECT query
    local query = sql.builder.select(
            "content_id", "upload_id", "mime_type", "content",
            "metadata", "created_at", "updated_at"
        )
        :from("upload_content")
        :where("content_id = ?", content_id)
        :limit(1)

    -- Execute the query
    local executor = query:run_with(db)
    local contents, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to get content: " .. err
    end

    if #contents == 0 then
        return nil, "Content not found"
    end

    local content = contents[1]

    -- Parse metadata JSON if it exists
    if content.metadata and content.metadata ~= "" then
        local decoded, err = json.decode(content.metadata)
        if not err then
            content.metadata = decoded
        else
            -- Fallback to empty table if JSON parsing fails
            content.metadata = {}
        end
    else
        content.metadata = {}
    end

    return content
end

-- Get content by upload ID
function content_repo.get_by_upload(upload_id)
    if not upload_id or upload_id == "" then
        return nil, "Upload ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Build the SELECT query
    local query = sql.builder.select(
            "content_id", "upload_id", "mime_type", "content",
            "metadata", "created_at", "updated_at"
        )
        :from("upload_content")
        :where("upload_id = ?", upload_id)
        :order_by("created_at DESC")
        :limit(1)

    -- Execute the query
    local executor = query:run_with(db)
    local contents, err = executor:query()

    db:release()

    if err then
        return nil, "Failed to get content: " .. err
    end

    if #contents == 0 then
        return nil, "Content not found for upload"
    end

    local content = contents[1]

    -- Parse metadata JSON if it exists
    if content.metadata and content.metadata ~= "" then
        local decoded, err = json.decode(content.metadata)
        if not err then
            content.metadata = decoded
        else
            -- Fallback to empty table if JSON parsing fails
            content.metadata = {}
        end
    else
        content.metadata = {}
    end

    return content
end

-- Update content
function content_repo.update_content(content_id, new_content, mime_type)
    if not content_id or content_id == "" then
        return nil, "Content ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the UPDATE query
    local query = sql.builder.update("upload_content")
        :set("updated_at", now)

    -- Add content if provided
    if new_content then
        query = query:set("content", new_content)
    end

    -- Add mime_type if provided
    if mime_type and mime_type ~= "" then
        query = query:set("mime_type", mime_type)
    end

    -- Add WHERE clause
    query = query:where("content_id = ?", content_id)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to update content: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Content not found"
    end

    return {
        content_id = content_id,
        updated_at = now,
        updated = true
    }
end

-- Update metadata (merges with existing metadata)
function content_repo.update_metadata(content_id, metadata)
    if not content_id or content_id == "" then
        return nil, "Content ID is required"
    end

    if type(metadata) ~= "table" then
        return nil, "Metadata must be a table"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- First get existing metadata
    local current, err = content_repo.get(content_id)
    if err then
        db:release()
        return nil, "Failed to get current metadata: " .. err
    end

    local current_metadata = current.metadata or {}

    -- Merge new metadata with existing
    for k, v in pairs(metadata) do
        current_metadata[k] = v
    end

    -- Convert merged metadata to JSON
    local metadata_json, err = json.encode(current_metadata)
    if err then
        db:release()
        return nil, "Failed to encode metadata: " .. err
    end

    local now = time.now():format(time.RFC3339)

    -- Build the UPDATE query
    local query = sql.builder.update("upload_content")
        :set("metadata", metadata_json)
        :set("updated_at", now)
        :where("content_id = ?", content_id)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to update metadata: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Content not found"
    end

    return {
        content_id = content_id,
        updated_at = now,
        metadata = current_metadata,
        updated = true
    }
end

-- Delete content
function content_repo.delete(content_id)
    if not content_id or content_id == "" then
        return nil, "Content ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Build the DELETE query
    local query = sql.builder.delete("upload_content")
        :where("content_id = ?", content_id)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to delete content: " .. err
    end

    if result.rows_affected == 0 then
        return nil, "Content not found"
    end

    return { deleted = true }
end

-- Delete all content for an upload
function content_repo.delete_by_upload(upload_id)
    if not upload_id or upload_id == "" then
        return nil, "Upload ID is required"
    end

    local db, err = get_db()
    if err then
        return nil, err
    end

    -- Build the DELETE query
    local query = sql.builder.delete("upload_content")
        :where("upload_id = ?", upload_id)

    -- Execute the query
    local executor = query:run_with(db)
    local result, err = executor:exec()

    db:release()

    if err then
        return nil, "Failed to delete content: " .. err
    end

    return {
        deleted = true,
        count = result.rows_affected
    }
end

return content_repo