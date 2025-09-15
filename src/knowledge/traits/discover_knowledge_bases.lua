local component = require("component")
local json = require("json")

local function handle(args)
    args = args or {}

    local limit = args.limit or 20

    local service, err = component.get_service()
    if err then
        return {
            success = false,
            error = "Failed to get component service: " .. err
        }
    end

    local request_dto = {
        filters = {
            meta = { class = "knowledge_base" }
        },
        pagination = {
            limit = limit,
            offset = 0
        }
    }

    local result, service_err = service:list_components(request_dto)
    if service_err then
        return {
            success = false,
            error = "Service call failed: " .. service_err
        }
    end

    if not result.success then
        return {
            success = false,
            error = result.error or "Service returned error"
        }
    end

    local kbs = result.components or {}

    return {
        success = true,
        count = #kbs,
        knowledge_bases = kbs,
        message = "Found " .. #kbs .. " knowledge base(s)"
    }
end

return { handle = handle }