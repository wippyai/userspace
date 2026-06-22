-- oauth_callback_page.lua
local http = require("http")
local json = require("json")
local renderer = require("renderer")
local log = require("logger"):named("userspace.oauth.api.public")

-- Constants
local STATUS = http.STATUS
local CONTENT = http.CONTENT
local VIEW_ID = "userspace.oauth.views:oauth_callback"

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Set HTML content type
    res:set_content_type("text/html")

    local params = {}
    local query = {}
    local code = req:query("code")
    local state = req:query("state")
    local error_param = req:query("error")
    local error_description = req:query("error_description")
    local provider = req:query("provider")

    if code then query.code = code end
    if state then query.state = state end
    if error_param then query.error = error_param end
    if error_description then query.error_description = error_description end
    if provider then query.provider = provider end

    -- Render the OAuth callback page using the renderer
    local content, err = renderer.render(VIEW_ID, params, query)

    if err then
        log:error("View not found", { error = tostring(err) })
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write("View not found")
        return
    end

    -- Return the rendered content
    res:set_status(STATUS.OK)
    res:write(content)
end

return {
    handler = handler
}