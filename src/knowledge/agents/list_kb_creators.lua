local registry = require("registry")
local json = require("json")

local function handle(args)
    args = args or {}

    -- Find all agents with "knowledge_base_creator" class
    local entries = registry.find({
        [".kind"] = "registry.entry",
        ["meta.type"] = "agent.gen1",
        ["*meta.class"] = "knowledge_base_creator"
    })

    if not entries then
        return {
            success = false,
            error = "Failed to search registry"
        }
    end

    -- Filter and format results
    local creators = {}
    for _, entry in ipairs(entries) do
        local class_meta = entry.meta and entry.meta.class
        local matches = false

        -- Check if "knowledge_base_creator" is in the class
        if type(class_meta) == "string" then
            matches = class_meta == "knowledge_base_creator"
        elseif type(class_meta) == "table" then
            for _, v in ipairs(class_meta) do
                if v == "knowledge_base_creator" then
                    matches = true
                    break
                end
            end
        end

        if matches then
            table.insert(creators, {
                id = entry.id,
                name = entry.meta.name,
                title = entry.meta.title,
                comment = entry.meta.comment,
                icon = entry.meta.icon,
                tags = entry.meta.tags
            })
        end
    end

    return {
        success = true,
        count = #creators,
        creators = creators,
        message = "Found " .. #creators .. " knowledge base creator(s)"
    }
end

return { handle = handle }