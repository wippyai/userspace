local http = require("http")
local security = require("security")
local json = require("json")
local time = require("time")

local upload_repo = require("upload_repo")

-- Handler to list user uploads
local function list_handler()
    local req = http.request()
    local res = http.response()

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    -- Set JSON content type for response
    res:set_content_type(http.CONTENT.JSON)

    -- Get current user from security context
    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    -- Get user ID from actor
    local user_id = actor:id()
    if not user_id or user_id == "" then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Invalid user ID"
        })
        return
    end

    -- Get query parameters
    local limit = tonumber(req:query("limit") or "20")
    local offset = tonumber(req:query("offset") or "0")

    -- Get total count of uploads for pagination
    local total_count, count_err = upload_repo.count_by_user(user_id)
    if count_err then
        -- Non-fatal error, just log it
        print("Failed to get total count: " .. count_err)
        total_count = 0
    end

    -- Get uploads for the user
    local uploads, err = upload_repo.list_by_user(user_id, limit, offset)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to list uploads",
            details = err
        })
        return
    end

    -- Format the uploads for frontend use
    local formatted_uploads = {}
    for i, upload in ipairs(uploads) do
        formatted_uploads[i] = {
            uuid = upload.uuid,
            size = upload.size,
            mime_type = upload.mime_type,
            status = upload.status,
            testField = 'TEST',
            created_at = upload.created_at,
            updated_at = upload.updated_at,
            filename = upload.metadata and upload.metadata.filename or nil,
            meta = upload.metadata
        }
    end

    -- Return success with uploads
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        uploads = formatted_uploads,
        meta = {
            limit = limit,
            offset = offset,
            total = total_count or #uploads
        }
    })
end

return {
    list_handler = list_handler
}
