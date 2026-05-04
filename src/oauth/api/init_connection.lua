local http = require("http")
local json = require("json")
local contract = require("contract")
local time = require("time")
local env = require("env")
local logger = require("logger"):named("userspace.oauth.api.init")

-- Constants
local STATUS = http.STATUS
local CONTENT = http.CONTENT
local OAUTH_CONNECTOR_CONTRACT = "userspace.oauth:connector"
local PROVIDER_DISCOVERY_CONTRACT = "userspace.oauth.discovery:provider_discovery"
local CONNECTION_NEGOTIATOR_PROCESS = "userspace.oauth.process:connection_negotiator"
local PROCESS_HOST = "app:processes"

-- Local function to construct redirect URI
local function build_redirect_uri(provider_name)
    local base_url, err = env.get("PUBLIC_API_URL")
    if err or not base_url or base_url == "" then
        return nil, "PUBLIC_API_URL environment variable not set"
    end

    -- Remove trailing slash if present
    if base_url:sub(-1) == "/" then
        base_url = base_url:sub(1, -2)
    end

    local redirect_uri = base_url .. "/api/public/userspace/oauth/callback"
    return redirect_uri, nil
end

local function handler()
    local req = http.request()
    local res = http.response()

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    -- Set JSON content type
    res:set_content_type(CONTENT.JSON)

    -- Only allow POST requests
    if req:method() ~= "POST" then
        res:set_status(STATUS.METHOD_NOT_ALLOWED)
        res:write_json({
            success = false,
            error = "Method not allowed. Use POST."
        })
        return
    end

    -- Get provider name from URL params
    local provider_name = req:param("provider_name")
    if not provider_name or provider_name == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Provider name is required in URL path"
        })
        return
    end

    -- Parse request body
    local body, parse_err = req:body_json()
    if parse_err then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Invalid JSON request body: " .. parse_err
        })
        return
    end

    -- Validate required fields
    if not body.name or body.name == "" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Connection name is required"
        })
        return
    end

    if not body.scopes or type(body.scopes) ~= "table" then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Scopes array is required"
        })
        return
    end

    -- Check if this is a re-authorization (component_id provided)
    local is_reauthorization = body.component_id and body.component_id ~= ""

    logger:debug("OAuth connection initialization started", {
        provider_name = provider_name,
        connection_name = body.name,
        scopes_count = #body.scopes,
        is_reauthorization = is_reauthorization,
        component_id = body.component_id or "new"
    })

    -- Build redirect URI
    local redirect_uri, uri_err = build_redirect_uri(provider_name)
    if uri_err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to build redirect URI: " .. uri_err
        })
        return
    end

    -- Get provider discovery service to find the provider
    local discovery_service, err = contract.get(PROVIDER_DISCOVERY_CONTRACT)
    if err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Discovery service not available: " .. err
        })
        return
    end

    -- Open discovery service
    local discovery_instance, err = discovery_service:open()
    if err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to open discovery service: " .. err
        })
        return
    end

    -- Get provider information for validation and display.
    -- The discovery contract returns {success=false, error=...} for unknown
    -- providers (no Lua-level err), so we have to inspect the result.
    local provider_info, err = discovery_instance:get_provider_info({
        oauth_provider = provider_name
    })

    if err or not provider_info or not provider_info.success then
        local detail = err or (provider_info and provider_info.error) or "unknown error"
        res:set_status(STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "Provider not found: " .. detail
        })
        return
    end

    -- Get connector contract details (implementation and context).
    -- Same defensive handling: a non-OAuth provider name yields a result
    -- with success=false instead of a Lua error.
    local connector_info, err = discovery_instance:get_connector_contract({
        oauth_provider = provider_name
    })

    if err or not connector_info or not connector_info.success
        or type(connector_info.context_values) ~= "table"
        or not connector_info.implementation_id then
        local detail = err
            or (connector_info and connector_info.error)
            or "connector contract incomplete"
        res:set_status(STATUS.NOT_FOUND)
        res:write_json({
            success = false,
            error = "OAuth connector not available for provider '" .. provider_name .. "': " .. detail
        })
        return
    end

    -- Get the OAuth connector contract
    local oauth_contract, err = contract.get(OAUTH_CONNECTOR_CONTRACT)
    if err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "OAuth contract not available: " .. err
        })
        return
    end

    -- Open OAuth contract instance with provider-specific context from discovery
    local oauth_instance, err = oauth_contract
        :with_context(connector_info.context_values)
        :open(connector_info.implementation_id :: string)

    if err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to open OAuth implementation: " .. err
        })
        return
    end

    -- Merge default scopes with requested scopes (default scopes are ALWAYS included)
    local final_scopes = {}
    local scope_set = {} -- For deduplication

    -- First, add all default scopes
    local default_scopes = provider_info.default_scopes or {}
    for _, scope in ipairs(default_scopes) do
        if not scope_set[scope] then
            table.insert(final_scopes, scope)
            scope_set[scope] = true
        end
    end

    -- Then, add requested scopes (if not already included)
    local requested_scopes = body.scopes or {}
    for _, scope in ipairs(requested_scopes) do
        if not scope_set[scope] then
            table.insert(final_scopes, scope)
            scope_set[scope] = true
        end
    end

    logger:debug("Scope merging completed", {
        provider_name = provider_name,
        default_scopes = default_scopes,
        requested_scopes = requested_scopes,
        final_scopes = final_scopes,
        total_scope_count = #final_scopes,
        is_reauthorization = is_reauthorization
    })

    -- Call init_oauth method to generate authorization URL and state with merged scopes
    local init_result, err = oauth_instance:init_oauth({
        redirect_uri = redirect_uri,
        scopes = final_scopes  -- Use merged scopes (default + requested)
    })

    if err then
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to initialize OAuth flow: " .. err
        })
        return
    end

    if not init_result.success then
        res:set_status(STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = init_result.error or "OAuth initialization failed"
        })
        return
    end

    -- Prepare connection data for the negotiator process
    local connection_data = {
        provider_name = provider_name,
        connection_name = body.name,
        connection_description = body.description or "",
        component_id = body.component_id or nil, -- Include component_id for updates
        oauth_data = init_result.storage_payload
    }

    -- Spawn connection negotiator process to handle OAuth callback and token exchange
    local negotiator_pid, spawn_err = process.spawn(
        CONNECTION_NEGOTIATOR_PROCESS,
        PROCESS_HOST,
        {
            state_token = init_result.state_token,
            connection_data = connection_data,
            connector_info = connector_info
        }
    )

    if not negotiator_pid then
        logger:debug("Failed to spawn OAuth negotiator process", {
            state_token = init_result.state_token,
            provider_name = provider_name,
            process_id = CONNECTION_NEGOTIATOR_PROCESS,
            host = PROCESS_HOST,
            spawn_error = spawn_err or "No error message"
        })
        res:set_status(STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to create OAuth session: " .. (spawn_err or "Unknown spawn error")
        })
        return
    end

    logger:debug("OAuth negotiator process spawned", {
        state_token = init_result.state_token,
        provider_name = provider_name,
        negotiator_pid = negotiator_pid,
        expires_in = init_result.expires_in,
        is_reauthorization = is_reauthorization,
        final_scopes = final_scopes
    })

    -- Return success response with authorization URL
    res:set_status(STATUS.OK)
    res:write_json({
        success = true,
        authorization_url = init_result.authorization_url,
        state_token = init_result.state_token,
        expires_in = init_result.expires_in,
        redirect_uri = redirect_uri,
        is_reauthorization = is_reauthorization,
        provider = {
            name = provider_info.name,
            title = provider_info.title
        }
    })
end

return {
    handler = handler
}