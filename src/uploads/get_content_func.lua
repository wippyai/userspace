local content_repo = require("content_repo")
local upload_repo = require("upload_repo")
local security = require("security")
local ctx = require("ctx")

local function handle(args)
    args = args or {}

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

    -- Only get content from upload_content table
    local content, err = content_repo.get_by_upload(upload_id)
    if err then
        return nil, "Failed to get content: " .. err
    end

    return {
        content = content.content or "",
        content_type = content.mime_type or upload.mime_type,
        size = content.content and #content.content or 0,
        storage_id = upload.storage_id,
        storage_path = upload.storage_path,
        metadata = content.metadata or {}
    }
end

return { handle = handle }