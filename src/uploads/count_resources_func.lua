local security = require("security")
local json = require("json")
local upload_repo = require("upload_repo")

local function handle(args)
    args = args or {}

    -- Get current user
    local actor = security.actor()
    if not actor then
        return nil, "No authenticated user found"
    end

    local user_id = actor:id()
    local can_view_all = security.can("view_all", "uploads")

    -- If user can't view all and no user_id, deny access
    if not can_view_all and not user_id then
        return nil, "Access denied"
    end

    -- Extract filters
    local filters = args.filters or {}

    -- Build filter options for upload_repo
    local repo_options = {
        user_id = can_view_all and nil or user_id, -- nil means all users if admin
        filters = filters
    }

    -- Get count from repo
    local count, err = upload_repo.count_with_filters(repo_options)
    if err then
        return nil, "Failed to count uploads: " .. err
    end

    return {
        total_count = count
    }
end

return { handle = handle }