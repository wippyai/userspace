local security = require("security")
local contract = require("contract")

local function handle(args)
    args = args or {}

    -- Validate user authentication
    local actor = security.actor()
    if not actor then
        return "Error: Authentication required to list files"
    end

    -- Validate limit
    local limit = args.limit or 20
    if limit < 1 or limit > 50 then
        return "Error: Limit must be between 1 and 50"
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
    local request = {
        limit = limit,
        sort = args.sort or "created_at",
        sort_order = args.sort_order or "desc"
    }

    if args.after_file_id then
        request.after_upload_id = args.after_file_id
    end

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

    -- Call list_resources method
    local result, err = instance:list_resources(request)
    if err then
        return "Error: Failed to list files: " .. err
    end

    -- Format response
    local response_parts = {"## Your Files\n"}

    if #result.items == 0 then
        table.insert(response_parts, "No files found matching your criteria.\n")
        return table.concat(response_parts)
    end

    -- Add files list
    for i, file in ipairs(result.items) do
        local size_str = ""
        if file.size then
            if file.size > 1024*1024 then
                size_str = string.format("%.1f MB", file.size / (1024*1024))
            elseif file.size > 1024 then
                size_str = string.format("%.1f KB", file.size / 1024)
            else
                size_str = file.size .. " bytes"
            end
        end

        table.insert(response_parts, string.format(
            "**%s** (%s)\n- ID: `%s`\n- Type: %s\n- Created: %s\n\n",
            file.filename or "Unknown",
            size_str,
            file.id,
            file.content_type,
            file.created_at or "Unknown"
        ))
    end

    -- Add pagination info
    if result.has_more then
        local last_id = result.items[#result.items].id
        table.insert(response_parts, string.format(
            "**Showing %d files** • Use `after_file_id: \"%s\"` to see more\n",
            #result.items,
            last_id
        ))
    else
        table.insert(response_parts, string.format("**Showing all %d files**\n", #result.items))
    end

    return table.concat(response_parts)
end

return { handle = handle }