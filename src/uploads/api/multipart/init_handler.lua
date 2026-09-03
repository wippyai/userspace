local http = require("http")
local request_context = require("request_context")
local upload_lib = require("upload_lib")

local function handler()
    local ctx = request_context.get()
    if not ctx then
        return
    end
    local res, body = ctx.res, ctx.body

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

    local metadata = body.metadata or {}

    if body.upload_token then
        metadata.__upload_token = body.upload_token
    end

    local created, err = upload_lib.create_multipart_upload(
        ctx.user_id,
        body.filename,
        body.size,
        body.content_type,
        metadata
    )

    if err then
        local status, payload = upload_lib.failure_response(err, "Failed to create multipart upload")
        res:set_status(status)
        res:write_json(payload)
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        upload_id = created.upload_id,
        object_key = created.object_key,
        part_size = created.part_size,
        min_part_size = created.min_part_size,
        max_parts = created.max_parts
    })
end

return {
    handler = handler
}
