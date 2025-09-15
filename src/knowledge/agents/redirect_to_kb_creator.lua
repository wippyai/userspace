local registry = require("registry")
local json = require("json")

local function handle(args)
    args = args or {}

    if not args.creator_id then
        return {
            success = false,
            error = "creator_id is required"
        }
    end

    -- Get the creator agent
    local creator_entry, err = registry.get(args.creator_id)
    if err then
        return {
            success = false,
            error = "Failed to get creator agent: " .. err
        }
    end

    if not creator_entry then
        return {
            success = false,
            error = "Creator agent not found: " .. args.creator_id
        }
    end

    -- Verify it's a valid agent
    if not creator_entry.meta or creator_entry.meta.type ~= "agent.gen1" then
        return {
            success = false,
            error = "Entry is not a valid agent: " .. args.creator_id
        }
    end

    -- Check if it has knowledge_base_creator class
    local class_meta = creator_entry.meta.class
    local is_creator = false

    if type(class_meta) == "string" then
        is_creator = class_meta == "knowledge_base_creator"
    elseif type(class_meta) == "table" then
        for _, v in ipairs(class_meta) do
            if v == "knowledge_base_creator" then
                is_creator = true
                break
            end
        end
    end

    if not is_creator then
        return {
            success = false,
            error = "Agent is not a knowledge base creator: " .. args.creator_id
        }
    end

    return {
        success = true,
        _control = {
            config = {
                agent = args.creator_id
            }
        }
    }
end

return { handle = handle }
