local json = require("json")
local time = require("time")
local oauth_repo = require("oauth_repo")
local contract = require("contract")
local logger = require("logger"):named("userspace.oauth.process.token_refresh")

-- Constants
local OAUTH_CONNECTOR_CONTRACT = "userspace.oauth:connector"
local PROVIDER_DISCOVERY_CONTRACT = "userspace.oauth.discovery:provider_discovery"

local function handle(request_dto)
    local schedule_id = request_dto.schedule_id or "unknown"
    local args = request_dto.args or {}
    local component_id = args.component_id

    if not component_id then
        logger:error("Missing component_id in task arguments")
        return {
            success = false,
            error = "Missing component_id in task arguments",
            retriable = false
        }
    end

    logger:debug("Token refresh started", {
        component_id = component_id,
        schedule_id = schedule_id
    })

    -- Get connection metadata (lightweight check)
    local connection_metadata, err = oauth_repo.get_connection_metadata(component_id)
    if err then
        logger:error("Failed to get connection metadata", {
            component_id = component_id,
            error = err
        })
        return {
            success = false,
            error = "Failed to get connection metadata: " .. err,
            retriable = true
        }
    end

    local provider_name = connection_metadata.provider

    logger:info("Token refresh required, starting process", {
        component_id = component_id,
        provider = provider_name,
        connection_name = connection_metadata.connection_name
    })

    -- Get full connection data
    local connection_data, err = oauth_repo.get_connection(component_id)
    if err then
        logger:error("Failed to get connection data", {
            component_id = component_id,
            error = err
        })
        return {
            success = false,
            error = "Failed to get connection data: " .. err,
            retriable = true
        }
    end

    -- Verify refresh token is available
    if not connection_data.tokens or not connection_data.tokens.refresh_token then
        logger:warn("No refresh token available for connection", {
            component_id = component_id,
            provider = provider_name
        })
        return {
            success = false,
            error = "No refresh token available - manual re-authorization required",
            retriable = false
        }
    end

    -- Get provider connector
    local discovery_service, err = contract.get(PROVIDER_DISCOVERY_CONTRACT)
    if err then
        logger:error("Failed to get discovery service", { error = err })
        return {
            success = false,
            error = "Failed to get discovery service: " .. err,
            retriable = true
        }
    end

    local discovery_instance, err = discovery_service:open()
    if err then
        logger:error("Failed to open discovery service", { error = err })
        return {
            success = false,
            error = "Failed to open discovery service: " .. err,
            retriable = true
        }
    end

    local connector_info, err = discovery_instance:get_connector_contract({
        oauth_provider = provider_name
    })
    if err then
        logger:error("Failed to get connector contract", {
            provider = provider_name,
            error = err
        })
        return {
            success = false,
            error = "Failed to get connector contract: " .. err,
            retriable = true
        }
    end

    -- Get OAuth contract and instance
    local oauth_contract, err = contract.get(OAUTH_CONNECTOR_CONTRACT)
    if err then
        logger:error("Failed to get OAuth contract", { error = err })
        return {
            success = false,
            error = "Failed to get OAuth contract: " .. err,
            retriable = true
        }
    end

    local oauth_instance, err = oauth_contract
        :with_context(connector_info.context_values)
        :open(connector_info.implementation_id :: string)
    if err then
        logger:error("Failed to open OAuth implementation", {
            implementation_id = connector_info.implementation_id,
            error = err
        })
        return {
            success = false,
            error = "Failed to open OAuth implementation: " .. err,
            retriable = true
        }
    end

    -- Perform token refresh
    local refresh_result, err = oauth_instance:refresh_token({
        refresh_token = connection_data.tokens.refresh_token
    })

    if err then
        logger:error("Token refresh call failed", {
            component_id = component_id,
            provider = provider_name,
            error = err
        })
        return {
            success = false,
            error = "Token refresh call failed: " .. err,
            retriable = true  -- Contract call failures are generally retriable
        }
    end

    if not refresh_result.success then
        local error_msg = refresh_result.error or "Unknown error"
        -- Use response_received to determine if we should retry
        local is_retriable = not refresh_result.response_received

        logger:error("Token refresh failed", {
            component_id = component_id,
            provider = provider_name,
            error = error_msg,
            response_received = refresh_result.response_received,
            is_retriable = is_retriable
        })

        return {
            success = false,
            error = "Token refresh failed: " .. error_msg,
            retriable = is_retriable
        }
    end

    -- Calculate new expiration
    local new_expires_at = nil
    if refresh_result.expires_in then
        new_expires_at = time.now():unix() + refresh_result.expires_in
    end

    -- Prepare updated tokens
    local new_tokens = {
        access_token = refresh_result.access_token,
        refresh_token = refresh_result.refresh_token or connection_data.tokens.refresh_token,
        token_type = refresh_result.token_type or connection_data.tokens.token_type,
        scope = refresh_result.scope or connection_data.tokens.scope
    }

    -- Update storage
    local update_result, err = oauth_repo.update_tokens(component_id, new_tokens, new_expires_at)
    if err then
        logger:error("Failed to update tokens in storage", {
            component_id = component_id,
            error = err
        })
        return {
            success = false,
            error = "Failed to update tokens: " .. err,
            retriable = true
        }
    end

    logger:info("Token refresh completed successfully", {
        component_id = component_id,
        provider = provider_name,
        new_expires_at = new_expires_at,
        token_rotated = refresh_result.refresh_token ~= nil
    })

    return { success = true }
end

return { handle = handle }