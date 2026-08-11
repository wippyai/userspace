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

    if type(body.parts) ~= "table" or #body.parts == 0 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing required field: parts"
        })
        return
    end

    local parts_list: {{part_number: number, etag: string}} = {}
    for i, p in ipairs(body.parts) do
        if type(p) ~= "table" or type(p.part_number) ~= "number" or not p.etag or p.etag == "" then
            res:set_status(http.STATUS.BAD_REQUEST)
            res:write_json({
                success = false,
                error = "parts must be an array of {part_number, etag}"
            })
            return
        end
        parts_list[i] = { part_number = p.part_number :: number, etag = tostring(p.etag) }
    end

    local metadata_updates = body.metadata or {}

    if body.upload_token then
        metadata_updates.__upload_token = body.upload_token
    end

    local upload, err = upload_lib.complete_multipart_upload(
        ctx.user_id,
        body.upload_id,
        parts_list,
        metadata_updates
    )

    if err then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "Failed to complete upload",
            details = err
        })
        return
    end

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
