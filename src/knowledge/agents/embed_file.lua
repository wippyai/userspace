local json = require("json")
local ctx = require("ctx")
local component = require("component")

local CONTENT_PROVIDER_BINDING_ID = "userspace.uploads:content_provider"

local function handle(args)
    args = args or {}

    if not args.upload_uuid then
        return {
            success = false,
            error = "upload_uuid is required"
        }
    end

    -- Get kb_id from context (set by KB specialist agent)
    local kb_id = ctx.get("kb_id")
    if not kb_id then
        return {
            success = false,
            error = "No kb_id found in context - this tool requires KB specialist context"
        }
    end

    -- Open the KB with write access
    local kb_instance, kb_err = component.open(kb_id, component.ACCESS.WRITE, "userspace.knowledge:embeddable")
    if not kb_instance then
        return {
            success = false,
            error = "Failed to open knowledge base: " .. (kb_err or "unknown error")
        }
    end

    -- Prepare embed reference request using uploads content provider
    local embed_request = {
        reference = {
            binding_id = CONTENT_PROVIDER_BINDING_ID,
            context = {
                upload_id = args.upload_uuid
            }
        },
        metadata = args.metadata or {}
    }

    -- Embed the file content into KB
    local result, embed_err = kb_instance:embed_reference(embed_request)
    if embed_err then
        return {
            success = false,
            error = "Failed to embed file: " .. embed_err
        }
    end

    if not result.success then
        return {
            success = false,
            error = result.error or "Embed operation failed"
        }
    end

    return {
        success = true,
        kb_id = kb_id,
        upload_uuid = args.upload_uuid,
        ops_executed = result.ops_executed or 0,
        retrieved_content_type = result.retrieved_content_type,
        message = string.format("Successfully embedded file %s into knowledge base (%d operations)",
                               args.upload_uuid, result.ops_executed or 0)
    }
end

return { handle = handle }