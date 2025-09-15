local http = require("http")
local security = require("security")
local json = require("json")
local time = require("time")

local user_repo = require("user_repo")
local user_groups_repo = require("user_groups_repo")
local consts = require("consts")

local function handler()
    local res = http.response()
    local req = http.request()

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    res:set_content_type(http.CONTENT.JSON)

    local body, err = req:body_json()
    if err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Invalid JSON request",
            details = err
        })
        return
    end

    local identifier = body.user_id or body.email
    if not identifier or identifier == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing user_id or email field"
        })
        return
    end

    local password = body.password
    if not password or password == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing password field"
        })
        return
    end

    local user, err = user_groups_repo.get_user_with_groups(identifier)
    if err then
        if err == consts.ERROR.USER_NOT_FOUND then
            res:set_status(http.STATUS.UNAUTHORIZED)
            res:write_json({
                success = false,
                error = "Invalid credentials"
            })
            return
        end

        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Authentication system error",
            details = err
        })
        return
    end

    if user.status ~= consts.USER_STATUS.ACTIVE then
        res:set_status(http.STATUS.FORBIDDEN)
        res:write_json({
            success = false,
            error = "Account is not active",
            status = user.status
        })
        return
    end

    local password_valid, verify_err = user_repo.verify_password(identifier, password)
    if not password_valid then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Invalid credentials"
        })
        return
    end

    local config = consts.get_config()

    local actor_metadata = {
        user_id = user.user_id,
        email = user.email,
        full_name = user.full_name,
        status = user.status,
        security_groups = user.security_groups or {},
        login_time = time.now():format_rfc3339(),
        ip_address = req:remote_addr() or "unknown",
        user_agent = req:header("User-Agent") or "unknown"
    }

    if body.metadata then
        for key, value in pairs(body.metadata) do
            if key ~= "security_groups" then
                actor_metadata[key] = value
            end
        end
    end

    local actor = security.new_actor(user.user_id, actor_metadata)

    local scope_id = config.default_group_id
    local is_admin = false

    if user.security_groups then
        for _, group_id in ipairs(user.security_groups) do
            if group_id == config.admin_group_id then
                scope_id = config.admin_group_id
                is_admin = true
                break
            else
                scope_id = group_id
            end
        end
    end

    local scope, err = security.named_scope(scope_id)
    if not scope then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to get security scope",
            details = err or "Scope not found"
        })
        return
    end

    local token_store, err = security.token_store(config.token_store)
    if not token_store then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to get token store",
            details = err or "Unknown error"
        })
        return
    end

    local token_meta = {
        ip = req:remote_addr() or "unknown",
        user_agent = req:header("User-Agent") or "unknown",
        created_at = time.now():format_rfc3339(),
        security_groups = user.security_groups,
        scope_used = scope_id,
        is_admin = is_admin
    }

    local token, err = token_store:create(actor, scope, {
        expiration = config.token_expiration,
        meta = token_meta
    })

    token_store:close()

    if not token then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = consts.ERROR.TOKEN_CREATION_FAILED,
            details = err or "Unknown error"
        })
        return
    end

    local response = {
        success = true,
        message = "Authentication successful",
        token = token,
        user = {
            user_id = user.user_id,
            email = user.email,
            full_name = user.full_name,
            status = user.status,
            created_at = user.created_at
        },
        actor = {
            id = actor:id(),
            metadata = actor:meta()
        },
        security = {
            groups = user.security_groups,
            scope = scope_id,
            is_admin = is_admin
        },
        expiration = config.token_expiration
    }

    res:set_status(http.STATUS.OK)
    res:write_json(response)
end

return {
    handler = handler
}