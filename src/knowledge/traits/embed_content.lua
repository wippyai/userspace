local component = require("component")
local json = require("json")
local ctx = require("ctx")

local function handle(args)
    args = args or {}

    if not args.content then
        return {
            success = false,
            error = "content is required"
        }
    end

    -- Get kb_id from context
    local kb_id = ctx.get("kb_id")
    if not kb_id then
        return {
            success = false,
            error = "No kb_id found in context"
        }
    end

    local instance, err = component.open(kb_id, component.ACCESS.WRITE, "userspace.knowledge:embeddable")
    if err then
        return {
            success = false,
            error = "Failed to open knowledge base: " .. err
        }
    end

    local embed_request = {
        content = args.content,
        content_type = args.content_type or "text/plain",
        metadata = args.metadata or {}
    }

    local result, embed_err = instance:embed(embed_request)
    if embed_err then
        return {
            success = false,
            error = "Embed failed: " .. embed_err
        }
    end

    local embedded_count = result.embedded_count or 0

    return {
        success = true,
        kb_id = kb_id,
        embedded_count = embedded_count,
        message = "Embedded " .. embedded_count .. " item(s) into knowledge base"
    }
end

return { handle = handle }