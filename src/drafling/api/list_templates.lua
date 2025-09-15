local http = require("http")
local json = require("json")
local template_registry = require("template_registry")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Parse query parameters
    local filters = {}

    local search = req:query("search")
    if search and search ~= "" then
        filters.search = search
    end

    local tags = req:query("tags")
    if tags and tags ~= "" then
        filters.tags = {}
        for tag in tags:gmatch("[^,]+") do
            table.insert(filters.tags, tag:match("^%s*(.-)%s*$")) -- trim whitespace
        end
    end

    local templates, err = template_registry.list_templates(filters)
    if not templates then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = err or "Failed to list templates"
        })
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        count = #templates,
        templates = templates
    })
end

return {
    handler = handler
}