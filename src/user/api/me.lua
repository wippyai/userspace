local http = require("http")
local security = require("security")
local json = require("json")
local time = require("time")

-- Import our repositories and constants
local user_groups_repo = require("user_groups_repo")
local consts = require("consts")
local api_error = require("api_error")

-- User profile endpoint handler - returns current authenticated user info with security groups
local function handler()
    local res = http.response()
    local req = http.request()

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    -- Set JSON content type
    res:set_content_type(http.CONTENT.JSON)

    -- Get current actor from security context
    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Authentication required",
            details = "This endpoint requires a valid authentication token"
        })
        return
    end

    -- Get current scope from security context
    local scope = security.scope()
    if not scope then
        res:set_status(http.STATUS.FORBIDDEN)
        res:write_json({
            success = false,
            error = "Authorization required",
            details = "No authorization scope available"
        })
        return
    end

    -- Extract user ID from actor
    local user_id = actor:id()
    if not user_id then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Invalid actor context",
            details = "Unable to determine user identity"
        })
        return
    end

    -- Get fresh user security groups from database
    local user_groups, err = user_groups_repo.get_user_groups(user_id)
    if err then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to retrieve user security groups", err)
        return
    end

    -- Get actor metadata (which should include security groups from login)
    local actor_metadata = actor:meta() or {}

    -- Get configuration to determine admin status and current scope
    local config = consts.get_config()
    local is_admin = false
    local current_scope_id = config.default_group_id

    -- Check if user is admin based on current groups and determine current scope
    if user_groups.groups then
        for _, group_id in ipairs(user_groups.groups) do
            if group_id == config.admin_group_id then
                is_admin = true
                current_scope_id = config.admin_group_id  -- Admin group used as scope
                break
            else
                -- Use first non-admin group as scope
                current_scope_id = group_id
            end
        end
    end

    -- Build comprehensive user profile response (compatible with old me.lua format)
    local profile = {
        success = true,
        message = "User profile retrieved successfully",
        user = {
            id = user_id,
            user_id = user_id,  -- Compatibility with old format
            email = actor_metadata.email,
            full_name = actor_metadata.full_name,
            status = actor_metadata.status,
            created_at = actor_metadata.created_at,
            metadata = actor_metadata,  -- Compatibility with old format
            timestamp = time.now():format_rfc3339()
        },
        security = {
            groups = user_groups.groups,
            is_admin = is_admin,
            scope = current_scope_id,  -- Current scope is based on groups
            permissions = {
                can_admin = is_admin,
                can_manage_users = is_admin,
                can_view_system = is_admin
            }
        },
        session = {
            login_time = actor_metadata.login_time,
            ip_address = actor_metadata.ip_address,
            user_agent = actor_metadata.user_agent,
            timestamp = time.now():format_rfc3339()
        }
    }

    -- Add additional request metadata if available
    local current_ip = req:remote_addr()
    local current_ua = req:header("User-Agent")

    if current_ip and current_ip ~= actor_metadata.ip_address then
        profile.session.current_ip_address = current_ip
        profile.session.ip_changed = true
    end

    if current_ua and current_ua ~= actor_metadata.user_agent then
        profile.session.current_user_agent = current_ua
        profile.session.user_agent_changed = true
    end

    -- Return user profile
    res:set_status(http.STATUS.OK)
    res:write_json(profile)
end

return {
    handler = handler
}