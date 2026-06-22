local http = require("http")
local json = require("json")
local contract = require("contract")
local component = require("component")
local oauth_repo = require("oauth_repo")
local api_error = require("api_error")

local STATUS = http.STATUS
local CONTENT = http.CONTENT
local DISCOVERY_SERVICE_CONTRACT = "userspace.oauth.discovery:provider_discovery"

local function handler()
    local req = http.request()
    local res = http.response()

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    res:set_content_type(CONTENT.JSON)

    if req:method() ~= "PUT" then
        res:set_status(STATUS.METHOD_NOT_ALLOWED)
        res:write_json({
            success = false,
            error = "Method not allowed. Use PUT."
        })
        return
    end

    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Component ID is required in URL path"
        })
        return
    end

    local body, parse_err = req:body_json()
    if parse_err then
        api_error.fail(res, STATUS.BAD_REQUEST, "Invalid JSON request body", parse_err)
        return
    end

    if not body.connection_name or body.connection_name == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Connection name is required"
        })
        return
    end

    -- Validate component access with WRITE permissions (bitmask value 2)
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.WRITE)
    if not access_level or access_level == 0 then
        api_error.fail(res, STATUS.FORBIDDEN, "Insufficient permissions to update this connection", access_err)
        return
    end

    -- Get existing OAuth connection to verify it exists
    local connection, err = oauth_repo.get_connection(component_id)
    if err then
        api_error.fail(res, STATUS.NOT_FOUND, "OAuth connection not found", err)
        return
    end

    -- Update component metadata (title and description) using component service
    local service, err = component.get_service()
    if err then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to get component service", err)
        return
    end

    -- Update component metadata with title and description
    local update_commands = {
        {
            type = "PUT_META",
            payload = {
                title = body.connection_name,
                description = body.connection_description or ""
            }
        }
    }

    local update_result, update_err = service:update_component({
        component_id = component_id,
        commands = update_commands
    })

    if update_err then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to update component metadata", update_err)
        return
    end

    if not update_result or not update_result.success then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = (update_result and update_result.error) or "Failed to update component metadata"
        })
        return
    end

    -- Update OAuth-specific connection data in the repository
    local connection_update = {
        connection_name = body.connection_name,
        connection_description = body.connection_description or ""
    }

    local repo_result, repo_err = oauth_repo.update_connection(component_id, connection_update)
    if repo_err then
        api_error.fail(res, STATUS.INTERNAL_ERROR, "Failed to update connection data", repo_err)
        return
    end

    -- Get provider info for response
    local provider_info = nil
    local discovery_service, err = contract.get(DISCOVERY_SERVICE_CONTRACT)
    if not err then
        local discovery_instance, err = discovery_service:open()
        if not err then
            provider_info, err = discovery_instance:get_provider_info({
                oauth_provider = connection.provider
            })
        end
    end

    -- Fallback provider info if discovery fails
    if not provider_info then
        provider_info = {
            name = connection.provider,
            title = connection.provider
        }
    end

    -- Return success response
    res:set_status(STATUS.OK)
    res:write_json({
        success = true,
        component_id = component_id,
        connection_name = body.connection_name,
        connection_description = body.connection_description or "",
        provider = {
            name = provider_info.name,
            title = provider_info.title
        },
        updated_at = repo_result and repo_result.updated_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
    })
end

return {
    handler = handler
}