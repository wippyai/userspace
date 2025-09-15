local json = require("json")
local component = require("component")

local function handle(args)
    args = args or {}

    if not args.kb_id then
        return {
            success = false,
            error = "kb_id is required"
        }
    end

    -- Verify the KB exists and get its title
    local service, service_err = component.get_service()
    if service_err then
        return {
            success = false,
            error = "Failed to get component service: " .. service_err
        }
    end

    local kb_info, kb_err = service:get_component({
        component_id = args.kb_id
    })

    if kb_err then
        return {
            success = false,
            error = "Failed to get knowledge base info: " .. kb_err
        }
    end

    if not kb_info then
        return {
            success = false,
            error = "Knowledge base not found: " .. args.kb_id
        }
    end

    -- Get KB title for user-friendly display
    local kb_title = "Knowledge Base"
    if kb_info.meta and kb_info.meta.title then
        kb_title = kb_info.meta.title
    elseif kb_info.meta and kb_info.meta.name then
        kb_title = kb_info.meta.name
    end

    -- Redirect to specialist with KB context using proper session approach
    local control = {
        context = {
            session = {
                set = {
                    kb_id = args.kb_id,
                    kb_title = kb_title,
                    specialist_mode = true
                }
            },
            public_meta = {
                set = {
                    {
                        id = "knowledge_base",
                        title = kb_title,
                        display_name = "KB: " .. kb_title,
                        type = "knowledge_base",
                        icon = "tabler:database"
                    }
                }
            }
        },
        config = {
            agent = "userspace.knowledge.agents:kb_specialist"
        }
    }

    return {
        success = true,
        kb_id = args.kb_id,
        kb_title = kb_title,
        message = "Switching to " .. kb_title .. " specialist",
        kb = {
            id = args.kb_id,
            title = kb_title
        },
        agent = {
            id = "userspace.knowledge.agents:kb_specialist"
        },
        _control = control
    }
end

return { handle = handle }