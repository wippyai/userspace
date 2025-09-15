local security = require("security")
local contract = require("contract")

local function handle(args)
    args = args or {}

    -- Validate user authentication
    local actor = security.actor()
    if not actor then
        return "Error: Authentication required to count files"
    end

    -- Build filters object
    local filters = {}
    if args.content_types and #args.content_types > 0 then
        filters.content_types = args.content_types
    end
    if args.created_after then
        filters.created_after = args.created_after
    end
    if args.created_before then
        filters.created_before = args.created_before
    end

    -- Build request parameters
    local request = {}
    if next(filters) then
        request.filters = filters
    end

    -- Get resource registry contract and open instance
    local resource_contract, err = contract.get("userspace.contract:resource_registry")
    if err then
        return "Error: Failed to get resource registry contract: " .. err
    end

    local instance, err = resource_contract:open("userspace.uploads:content_provider")
    if err then
        return "Error: Failed to open uploads resource registry: " .. err
    end

    -- Call count_resources method
    local result, err = instance:count_resources(request)
    if err then
        return "Error: Failed to count files: " .. err
    end

    -- Format response
    local count = result.total_count or 0
    local response_parts = {}

    if count == 0 then
        table.insert(response_parts, "No files found matching your criteria.")
    elseif count == 1 then
        table.insert(response_parts, "Found 1 file matching your criteria.")
    else
        table.insert(response_parts, string.format("Found %d files matching your criteria.", count))
    end

    -- Add filter details if any were applied
    if next(filters) then
        table.insert(response_parts, "\n**Applied filters:**")

        if filters.content_types then
            table.insert(response_parts, "- Content types: " .. table.concat(filters.content_types, ", "))
        end

        if filters.created_after then
            table.insert(response_parts, "- Created after: " .. filters.created_after)
        end

        if filters.created_before then
            table.insert(response_parts, "- Created before: " .. filters.created_before)
        end
    end

    return table.concat(response_parts, "\n")
end

return { handle = handle }