local http = require("http")
local json = require("json")
local template_registry = require("template_registry")
local api_error = require("api_error")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local template_id = req:param("template_id")
    if not template_id or template_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "template_id path parameter is required"
        })
        return
    end

    local template, err = template_registry.get_template(template_id)
    if not template then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.NOT_FOUND, "Template not found", err)
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        template = template
    })
end

return {
    handler = handler
}