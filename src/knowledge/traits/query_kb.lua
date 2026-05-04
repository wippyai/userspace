local component = require("component")
local json = require("json")
local ctx = require("ctx")

local function handle(args)
    args = args or {}

    if not args.query then
        return {
            success = false,
            error = "query is required"
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

    local limit = args.limit or 10

    local instance, err = component.open(kb_id :: string, component.ACCESS.READ, "userspace.knowledge:queryable")
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
        kb_id = kb_id,
        query = args.query,
        count = count,
        items = items,
        message = "Found " .. count .. " result(s) for query: " .. args.query
    }
end

return { handle = handle }