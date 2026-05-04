local json = require("json")
local time = require("time")
local oauth_repo = require("oauth_repo")
local contract = require("contract")
local logger = require("logger"):named("userspace.oauth.process.token_refresh")

-- Constants
local OAUTH_CONNECTOR_CONTRACT = "userspace.oauth:connector"
local PROVIDER_DISCOVERY_CONTRACT = "userspace.oauth.discovery:provider_discovery"

-- Backoff schedule for transient refresh failures (seconds). Each entry is
-- the delay before the next attempt. Total wall time bounded by
-- timeout_seconds (default 300) and well within typical token lifetimes.
local TRANSIENT_BACKOFF_S = { 5, 15, 45 }

local function is_transient(refresh_result)
    if refresh_result.transient ~= nil then
        return refresh_result.transient
    end
    -- Backwards-compatible classification for older oauth implementations
    -- that only return response_received: a missing response is transient,
    -- everything else is treated as final.
    return not refresh_result.response_received
end

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

    -- Perform token refresh, with inline backoff for transient failures.
    -- Final failures (invalid_grant, invalid_client, etc.) return immediately.
    local refresh_result, err
    local attempts = 1 + #TRANSIENT_BACKOFF_S
    for attempt = 1, attempts do
        refresh_result, err = oauth_instance:refresh_token({
            refresh_token = connection_data.tokens.refresh_token
        })

        if err then
            -- Contract call failures (e.g. process supervisor errors) are
            -- inherently transient. Keep retrying until we exhaust the budget.
            logger:warn("Token refresh contract call failed", {
                component_id = component_id,
                provider = provider_name,
                attempt = attempt,
                error = err
            })
        elseif refresh_result.success then
            break  -- success, exit loop
        elseif not is_transient(refresh_result) then
            break  -- final failure, no point retrying
        else
            logger:warn("Token refresh transient failure", {
                component_id = component_id,
                provider = provider_name,
                attempt = attempt,
                error = refresh_result.error,
                status_code = refresh_result.status_code,
                provider_error = refresh_result.provider_error
            })
        end

        local delay = TRANSIENT_BACKOFF_S[attempt]
        if delay then
            time.sleep(delay .. "s")
        end
    end

    if err then
        return {
            success = false,
            error = "Token refresh call failed after retries: " .. err,
            retriable = true
        }
    end

    if not refresh_result.success then
        local error_msg = refresh_result.error or "Unknown error"
        local transient = is_transient(refresh_result)

        logger:error("Token refresh failed", {
            component_id = component_id,
            provider = provider_name,
            error = error_msg,
            status_code = refresh_result.status_code,
            provider_error = refresh_result.provider_error,
            transient = transient
        })

        -- For final (non-transient) failures we tell the scheduler not to
        -- retry — the schedule will be disabled and the user must re-authorize.
        -- For transient failures we already exhausted our inline budget; let
        -- the scheduler retry on the next ticker so we keep trying through a
        -- prolonged outage without disabling the connection.
        return {
            success = false,
            error = "Token refresh failed: " .. error_msg,
            retriable = transient
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