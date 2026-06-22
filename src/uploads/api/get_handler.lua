local http = require("http")
local security = require("security")
local json = require("json")
local time = require("time")

local upload_repo = require("upload_repo")

-- Format Unix timestamp for frontend
local function format_date(timestamp)
    if not timestamp then return nil end

    -- Convert to number if it's not already
    if type(timestamp) ~= "number" then
        timestamp = tonumber(timestamp)
    end

    -- If conversion failed, return original
    if not timestamp then return nil end

    -- Convert Unix timestamp to ISO 8601 format
    local date = time.unix(timestamp, 0)
    return date:format_rfc3339()
end

-- Handler to get a single upload by ID
local function get_handler()
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

    -- Get upload ID from path parameter
    local uuid = req:param("uuid")
    if not uuid or uuid == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Upload ID is required"
        })
        return
    end

    -- Get upload by ID
    local upload, err = upload_repo.get(uuid)
    if err then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "Upload not found",
            details = err
        })
        return
    end

    -- Check if the upload belongs to the current user
    if upload.user_id ~= user_id then
        res:set_status(http.STATUS.FORBIDDEN)
        res:write_json({
            success = false,
            error = "Access denied"
        })
        return
    end

    -- Return success with upload
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        upload = {
            uuid = upload.uuid,
            size = upload.size,
            mime_type = upload.mime_type,
            status = upload.status,
            created_at = format_date(upload.created_at),
            updated_at = format_date(upload.updated_at),
            meta = upload.metadata
        }
    })
end

return {
    get_handler = get_handler
}
