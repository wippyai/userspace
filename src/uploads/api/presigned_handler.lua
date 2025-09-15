local http = require("http")
local security = require("security")
local json = require("json")

local upload_lib = require("upload_lib")

-- Generate presigned S3 upload URL handler
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
    if not body.filename then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing required field: filename"
        })
        return
    end

    if not body.size or type(body.size) ~= "number" or body.size <= 0 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Invalid or missing file size"
        })
        return
    end

    -- Get content type or default to octet-stream
    local mime_type = body.content_type or "application/octet-stream"

    -- Set expiration for presigned URL (default: 15 minutes)
    local expires_in = body.expires_in or 900 -- in seconds

    -- Get optional metadata
    local metadata = body.metadata or {}

    -- Generate presigned URL
    local presigned_data, err = upload_lib.generate_presigned_url(
        user_id,
        body.filename,
        body.size,
        mime_type,
        expires_in,
        metadata
    )

    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to generate presigned URL",
            details = err
        })
        return
    end

    -- Return success with presigned URL data
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        presigned_url = presigned_data.url,
        upload_id = presigned_data.upload_id,
        fields = presigned_data.fields or {},
        expires_at = presigned_data.expires_at
    })
end

return {
    handler = handler
}