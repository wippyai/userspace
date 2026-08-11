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

    local part_numbers: {number} = {}
    if type(body.parts) == "table" and #body.parts > 0 then
        for i, n in ipairs(body.parts) do
            if type(n) ~= "number" then
                res:set_status(http.STATUS.BAD_REQUEST)
                res:write_json({
                    success = false,
                    error = "parts must be an array of part numbers"
                })
                return
            end
            part_numbers[i] = n :: number
        end
    elseif type(body.from) == "number" and type(body.to) == "number" then
        local from_part = body.from :: number
        local to_part = body.to :: number
        if from_part < 1 or to_part < from_part then
            res:set_status(http.STATUS.BAD_REQUEST)
            res:write_json({
                success = false,
                error = "Invalid part range"
            })
            return
        end
        for n = from_part, to_part do
            part_numbers[#part_numbers + 1] = n
        end
    end

    if #part_numbers == 0 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Provide parts (array) or from/to (range)"
        })
        return
    end

    if #part_numbers > 1000 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "At most 1000 part URLs per request; page the range"
        })
        return
    end

    local urls, err = upload_lib.multipart_part_urls(
        ctx.user_id,
        body.upload_id,
        part_numbers,
        tonumber(body.expires_in)
    )

    if err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Failed to generate part URLs",
            details = err
        })
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        urls = urls
    })
end

return {
    handler = handler
}
