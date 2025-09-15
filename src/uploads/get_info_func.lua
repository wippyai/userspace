local content_repo = require("content_repo")
local upload_repo = require("upload_repo")
local security = require("security")
local ctx = require("ctx")

local function handle()
    local upload_id, err = ctx.get("upload_id")
    if err then
        return nil, "Failed to get upload_id from context: " .. err
    end

    if not upload_id or upload_id == "" then
        return nil, "upload_id is required in context"
    end

    local upload, err = upload_repo.get(upload_id)
    if err then
        return nil, "Failed to get upload information: " .. err
    end

    local actor = security.actor()
    if not actor then
        return nil, "No authenticated user found"
    end

    local user_id = actor:id()
    local can_view_all = security.can("view_all", "uploads")

    if upload.user_id ~= user_id and not can_view_all then
        return nil, "Not authorized to access this content"
    end

    -- Try to get content record, but don't fail if missing
    local content, content_err = content_repo.get_by_upload(upload_id)

    -- Use content info if available, otherwise fall back to upload info
    local content_type = upload.mime_type
    local size = upload.size
    local metadata = upload.metadata or {}

    if not content_err and content then
        content_type = content.mime_type or content_type
        if content.content and type(content.content) == "string" then
            size = #content.content
        end
        if content.metadata then
            metadata = content.metadata
        end
    end

    -- Extract filename from upload metadata
    local filename = metadata.filename or metadata.original_filename or "unknown"

    return {
        content_type = content_type,
        size = size,
        filename = filename,
        storage_id = upload.storage_id,
        storage_path = upload.storage_path,
        created_at = upload.created_at,
        metadata = metadata
    }
end

return { handle = handle }