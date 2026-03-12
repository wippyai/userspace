local http = require("http")
local security = require("security")
local json = require("json")

local upload_lib = require("upload_lib")
local upload_repo = require("upload_repo")

local function delete_handler()
    local req = http.request()
    local res = http.response()

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    res:set_content_type(http.CONTENT.JSON)

    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Authentication required",
        })
        return
    end

    local user_id = actor:id()
    if not user_id or user_id == "" then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Invalid user ID",
        })
        return
    end

    local uuid = req:param("uuid")
    if not uuid or uuid == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Upload ID is required",
        })
        return
    end

    local upload, err = upload_repo.get(uuid)
    if err then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "Upload not found",
            details = err,
        })
        return
    end

    if upload.user_id ~= user_id then
        res:set_status(http.STATUS.FORBIDDEN)
        res:write_json({
            success = false,
            error = "Access denied",
        })
        return
    end

    local _, del_err = upload_lib.delete_upload(uuid)
    if del_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to delete upload",
            details = del_err,
        })
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
    })
end

return {
    delete_handler = delete_handler,
}
