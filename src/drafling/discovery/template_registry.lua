local registry = require("registry")
local json = require("json")

local template_registry = {}

function template_registry.get_template(template_id)
    if not template_id or template_id == "" then
        return nil, "Template ID is required"
    end

    local template, err = registry.get(template_id)
    if err then
        return nil, "Failed to get template: " .. err
    end

    if not template then
        return nil, "Template not found: " .. template_id
    end

    if not template.meta or template.meta.type ~= "drafling.template" then
        return nil, "Entry is not a drafling template: " .. template_id
    end

    return {
        id = template.id,
        name = template.meta.name or template_id,
        description = template.meta.comment or "",
        icon = template.meta.icon,
        tags = template.meta.tags or {},
        template = template.data.template or {},
    }
end

function template_registry.list_templates(filters)
    filters = filters or {}

    local templates, err = registry.find({
        ["meta.type"] = "drafling.template"
    })

    if err then
        return nil, "Failed to scan templates: " .. err
    end

    local result = {}
    for _, template in ipairs(templates or {}) do
        local template_info = {
            id = template.id,
            name = template.meta.name or template.id,
            description = template.meta.comment or "",
            icon = template.meta.icon,
            tags = template.meta.tags or {}
        }

        -- Apply tag filter if provided
        if filters.tags and #filters.tags > 0 then
            local has_tag = false
            for _, filter_tag in ipairs(filters.tags) do
                for _, template_tag in ipairs(template_info.tags) do
                    if template_tag == filter_tag then
                        has_tag = true
                        break
                    end
                end
                if has_tag then break end
            end
            if not has_tag then
                goto continue
            end
        end

        table.insert(result, template_info)
        ::continue::
    end

    return result
end

return template_registry