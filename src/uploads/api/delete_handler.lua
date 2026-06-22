local http = require("http")
local security = require("security")
local json = require("json")

local upload_repo = require("upload_repo")

-- Handler to delete a single upload by ID
local function delete_handler()
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

    -- Get upload by ID first to check ownership
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

    -- Delete the upload
    local result, err = upload_repo.delete(uuid)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to delete upload",
            details = err
        })
        return
    end

    -- Return success response
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        message = "Upload deleted successfully"
    })
end

return {
    delete_handler = delete_handler
}