local http = require("http")
local security = require("security")

local function get()
    local req, err = http.request()
    local res = http.response()

    if err then
        if res then
            res:set_status(http.STATUS.INTERNAL_ERROR)
            res:write_json({
                success = false,
                error = "Failed to create request context",
                details = err
            })
        end
        return nil
    end

    if not req or not res then
        return nil
    end

    res:set_content_type(http.CONTENT.JSON)

    if not req:is_content_type(http.CONTENT.JSON) then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Request must be application/json"
        })
        return nil
    end

    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return nil
    end

    local user_id = actor:id()
    if not user_id or user_id == "" then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Invalid user ID"
        })
        return nil
    end

    local body, body_err = req:body_json()
    if body_err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Failed to parse JSON body",
            details = body_err
        })
        return nil
    end

    return { req = req, res = res, user_id = user_id, body = body }
end

return {
    get = get
}
