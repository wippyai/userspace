local http = require("http")
local security = require("security")
local onboard_db = require("onboard_db")

-- Helper: get an actor or immediately give 401
local function get_actor_or_unauthorized(res)
    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return nil
    end

    return actor
end

-- Helper: get flag from parameters or 400
local function get_flag_or_bad_request(req, res)
    local flag = req:param("flag")
    if not flag or flag == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing flag in path"
        })
        return nil
    end

    return flag
end

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local actor = get_actor_or_unauthorized(res)
    if not actor then
        return
    end

    local flag = get_flag_or_bad_request(req, res)
    if not flag then
        return
    end

    local user_id = actor:id()
    local ok, err = onboard_db.save_onboarding_flag(user_id, flag)
    if not ok then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to save onboarding status: " .. (err or "unknown error")
        })
        return
    end

    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        message = "Onboarding completed successfully"
    })
end

local function get_multi_handler()
    local res = http.response()
    if not res then
        return nil, "Failed to get HTTP context"
    end

    local actor = get_actor_or_unauthorized(res)
    if not actor then
        return
    end

    local user_id = actor:id()
    local flags, err = onboard_db.get_onboarding_flags(user_id)

    if not flags then
        res:set_content_type(http.CONTENT.JSON)
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({ success = false, error = "Failed to get onboarding flags: " .. (err or "unknown error") })
        return
    end

    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json({ success = true, flags = flags })
end

local function delete_handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local actor = get_actor_or_unauthorized(res)
    if not actor then
        return
    end

    local flag = get_flag_or_bad_request(req, res)
    if not flag then
        return
    end

    local user_id = actor:id()
    local ok, err = onboard_db.delete_onboarding_flag(user_id, flag)
    if not ok then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({ success = false, error = "Failed to delete onboarding status: " .. (err or "unknown error") })
        return
    end

    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json({ success = true, message = "Onboarding flag deleted" })
end

return {
    handler = handler,
    get_multi_handler = get_multi_handler,
    delete_handler = delete_handler
}
