local http = require("http")
local request_context = require("request_context")
local upload_lib = require("upload_lib")

local function handler()
    local ctx = request_context.get()
    if not ctx then
        return
    end
    local res, body = ctx.res, ctx.body

    if not body.upload_id then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing required field: upload_id"
        })
        return
    end

    local _, err = upload_lib.abort_multipart_upload(ctx.user_id, body.upload_id)
    if err then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "Failed to abort upload",
            details = err
        })
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true
    })
end

return {
    handler = handler
}
