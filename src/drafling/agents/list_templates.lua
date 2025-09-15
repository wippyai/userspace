local json = require("json")
local template_registry = require("template_registry")

local function handler(params)
    local response = {
        success = false,
        templates = {},
        error = nil
    }

    params = params or {}

    local filters = {}

    if params.search and params.search ~= "" then
        filters.search = params.search
    end

    if params.tags and type(params.tags) == "table" and #params.tags > 0 then
        filters.tags = params.tags
    end

    local templates, err = template_registry.list_templates(filters)
    if err then
        response.error = "Failed to list templates: " .. err
        return response
    end

    response.success = true
    response.templates = templates or {}
    response.count = #response.templates
    return response
end

return { handler = handler }