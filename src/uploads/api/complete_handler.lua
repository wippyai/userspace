local http = require("http")
local security = require("security")
local json = require("json")

local upload_lib = require("upload_lib")

-- Complete S3 direct upload handler
local function handler()
    local req, err = http.request()
    local res = http.response()

    if err then
        -- Handle request creation error
        if res then
            res:set_status(http.STATUS.INTERNAL_ERROR)
            res:write_json({
                success = false,
                error = "Failed to create request context",
                details = err
            })
        end
        return
    end

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    -- Set JSON content type for response
    res:set_content_type(http.CONTENT.JSON)

    -- Check for proper JSON content
    if not req:is_content_type(http.CONTENT.JSON) then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Request must be application/json"
        })
        return
    end

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

    -- Parse JSON request body
    local body, err = req:body_json()
    if err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Failed to parse JSON body",
            details = err
        })
        return
    end

    -- Validate required fields
    if not body.upload_id then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing required field: upload_id"
        })
        return
    end

    local upload_id = body.upload_id
    local etag = body.etag -- Optional ETag from S3 response

    -- Additional metadata to update (optional)
    local metadata_updates = body.metadata or {}

    upload, err = upload_lib.complete_presigned_url(user_id, upload_id, etag, metadata_updates)

    if err then
        -- Handle specific error cases
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "Upload not found",
            details = err
        })
        return
    end

    -- Return success with upload record
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        uuid = upload.uuid,
        size = upload.size,
        mime_type = upload.mime_type,
        created_at = upload.created_at
    })
end

return {
    handler = handler
}