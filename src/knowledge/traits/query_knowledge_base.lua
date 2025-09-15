local component = require("component")
local json = require("json")

local function handle(args)
    args = args or {}

    if not args.kb_id then
        return {
            success = false,
            error = "kb_id is required"
        }
    end

    if not args.query then
        return {
            success = false,
            error = "query is required"
        }
    end

    local limit = args.limit or 10

    local instance, err = component.open(args.kb_id, component.ACCESS.READ, "userspace.knowledge:queryable")
    if err then
        return {
            success = false,
            error = "Failed to open knowledge base: " .. err
        }
    end

    local query_request = {
        query = args.query,
        limit = limit
    }

    local result, query_err = instance:query(query_request)
    if query_err then
        return {
            success = false,
            error = "Query failed: " .. query_err
        }
    end

    local items = result.items or {}
    local count = result.count or #items

    return {
        success = true,
        kb_id = args.kb_id,
        query = args.query,
        count = count,
        items = items,
        message = "Found " .. count .. " result(s) for query: " .. args.query
    }
end

return { handle = handle }