local time = require("time")
local contract = require("contract")
local uuid = require("uuid")
local oauth_repo = require("oauth_repo")

-- Constants
local NEGOTIATION_TIMEOUT = "5m"
local OAUTH_CONNECTOR_CONTRACT = "userspace.oauth:connector"
local COMPONENT_SERVICE_CONTRACT = "userspace.component:component_service"
local PROVIDER_DISCOVERY_CONTRACT = "userspace.oauth.discovery:provider_discovery"
local SCHEDULER_CONTRACT = "userspace.scheduler:scheduler"
local TOKEN_REFRESH_PROCESS = "userspace.oauth.process:token_refresh_scheduler"
local REGISTRY_PREFIX = "oauth:connection:"
local CALLBACK_TOPIC = "oauth_callback"
local REPLY_TOPIC = "oauth_callback_response"
local REFRESH_PERCENTAGE_THRESHOLD = 0.75 -- Refresh when 75% of token lifetime has passed

local function create_token_refresh_schedule(component_id, provider_name, connection_name, expires_at)
    -- Only create refresh schedule for tokens that actually expire
    if not expires_at then
        return nil, nil  -- No error, just no schedule needed for permanent tokens
    end

    local scheduler_contract, err = contract.get(SCHEDULER_CONTRACT)
    if err then
        return nil, "Failed to get scheduler contract: " .. err
    end

    local scheduler_instance, err = scheduler_contract:open()
    if err then
        return nil, "Failed to open scheduler: " .. err
    end

    local refresh_interval = "15m" -- default fallback

    local current_time = time.now():unix()
    local token_lifetime = expires_at - current_time

    if token_lifetime > 0 then
        local refresh_time = math.floor(token_lifetime * REFRESH_PERCENTAGE_THRESHOLD)

        if refresh_time >= 3600 then
            refresh_interval = math.floor(refresh_time / 3600) .. "h"
        elseif refresh_time >= 60 then
            refresh_interval = math.floor(refresh_time / 60) .. "m"
        else
            refresh_interval = math.max(30, refresh_time) .. "s"
        end
    end

    local schedule_request = {
        task_implementation_id = TOKEN_REFRESH_PROCESS,
        schedule_type = "ticker",
        schedule_expression = refresh_interval,
        description = "Token refresh for " .. connection_name,
        class = "component",
        task_args = {
            component_id = component_id,
            provider = provider_name,
            connection_name = connection_name
        },
        task_context = {
            oauth_connection = true,
            component_id = component_id
        },
        timeout_seconds = 300,
        max_retries = 3,
        enabled = true
    }

    local schedule_result, err = scheduler_instance:create_schedule(schedule_request)
    if err then
        return nil, "Failed to create token refresh schedule: " .. err
    end

    if not schedule_result.success then
        return nil, schedule_result.error or "Failed to create schedule"
    end

    return schedule_result.task_id
end

local function register_component(component_id, oauth_connection, user_context, provider_name, connection_name, connection_description)
    if component_id then
        -- Update existing component
        local connection_update_data = {
            provider = provider_name,
            connection_name = connection_name,
            connection_description = connection_description or "",
            scopes_granted = oauth_connection.scopes_granted,
            connection_state = oauth_connection.connection_state,
            token_type = oauth_connection.token_type,
            expires_at = oauth_connection.expires_at,
            refresh_expires_at = oauth_connection.expires_at and (oauth_connection.expires_at + (30 * 24 * 3600)),
            tokens = {
                access_token = oauth_connection.access_token,
                refresh_token = oauth_connection.refresh_token,
                id_token = oauth_connection.id_token,
                scope = oauth_connection.scope
            },
            client_credentials = oauth_connection.client_credentials or {},
            user_profile = user_context,
            provider_specific = oauth_connection.provider_specific or {},
            oauth_flow = oauth_connection.oauth_flow or {}
        }

        local oauth_result, oauth_err = oauth_repo.update_connection(component_id, connection_update_data)
        if oauth_err then
            return nil, "Failed to store OAuth connection: " .. oauth_err
        end

        -- Handle token refresh schedule if needed (only for expiring tokens).
        -- Treat the existing schedule_id as a hint, not a guarantee — it may
        -- point at a row that was deleted out from under us (e.g. by manual
        -- cleanup or a retention sweep). If get_schedule fails to find it,
        -- create a new schedule and overwrite the stale reference.
        local connection_metadata, metadata_err = oauth_repo.get_connection_metadata(component_id)
        if not metadata_err and oauth_connection.expires_at then
            local need_schedule = not connection_metadata.schedule_id
            if not need_schedule then
                local scheduler_contract, sc_err = contract.get(SCHEDULER_CONTRACT)
                if not sc_err and scheduler_contract then
                    local scheduler_instance, open_err = scheduler_contract:open()
                    if not open_err and scheduler_instance then
                        local existing, get_err = scheduler_instance:get_schedule({
                            schedule_id = connection_metadata.schedule_id
                        })
                        if get_err or not existing or not existing.success then
                            need_schedule = true
                        end
                    end
                end
            end
            if need_schedule then
                local schedule_id, schedule_err = create_token_refresh_schedule(component_id, provider_name, connection_name, oauth_connection.expires_at)
                if schedule_id and not schedule_err then
                    oauth_repo.update_schedule_id(component_id, schedule_id)
                end
            end
        end

        return component_id
    else
        -- Create new component
        local new_component_id = uuid.v4()

        -- Get discovery service
        local discovery_service, err = contract.get(PROVIDER_DISCOVERY_CONTRACT)
        if err then
            return nil, "Failed to get discovery service: " .. err
        end

        local discovery_instance, err = discovery_service:open()
        if err then
            return nil, "Failed to open discovery service: " .. err
        end

        local component_contract_info, err = discovery_instance:get_component_contract({
            oauth_provider = provider_name
        })
        if err then
            return nil, "Failed to get component contract: " .. err
        end

        -- Store OAuth connection data
        local oauth_connection_data = {
            provider = provider_name,
            connection_name = connection_name,
            connection_description = connection_description or "",
            scopes_granted = oauth_connection.scopes_granted,
            connection_state = oauth_connection.connection_state,
            token_type = oauth_connection.token_type,
            expires_at = oauth_connection.expires_at,
            refresh_expires_at = oauth_connection.expires_at and (oauth_connection.expires_at + (30 * 24 * 3600)),
            tokens = {
                access_token = oauth_connection.access_token,
                refresh_token = oauth_connection.refresh_token,
                id_token = oauth_connection.id_token,
                scope = oauth_connection.scope
            },
            client_credentials = oauth_connection.client_credentials or {},
            user_profile = user_context,
            provider_specific = oauth_connection.provider_specific or {},
            oauth_flow = oauth_connection.oauth_flow or {}
        }

        local oauth_result, oauth_err = oauth_repo.create_connection(new_component_id, oauth_connection_data)
        if oauth_err then
            return nil, "Failed to store OAuth connection: " .. oauth_err
        end

        -- Register component
        local component_service, err = contract.get(COMPONENT_SERVICE_CONTRACT)
        if err then
            oauth_repo.delete_connection(new_component_id)
            return nil, "Failed to get component service: " .. err
        end

        local service, err = component_service:open()
        if err then
            oauth_repo.delete_connection(new_component_id)
            return nil, "Failed to open component service: " .. err
        end

        local meta = {
            class = "connection",
            oauth_connection = true,
            provider = provider_name,
            display_id = component_contract_info.provider_id,
            type = "OAuth Connection",
            title = connection_name,
            description = connection_description or ("OAuth connection to " .. provider_name)
        }

        local register_request = {
            component_id = new_component_id,
            impl_id = component_contract_info.component_contract_id,
            meta = meta,
            private_context = { component_id = new_component_id }
        }

        local result, err = service:register_component(register_request)
        if err then
            oauth_repo.delete_connection(new_component_id)
            return nil, "Failed to register component: " .. err
        end

        if not result or not result.success then
            local error_msg = (result and result.error) or "Component registration failed"
            oauth_repo.delete_connection(new_component_id)
            return nil, "Failed to register component: " .. error_msg
        end

        -- Schedule token refresh (only for expiring tokens)
        if oauth_connection.expires_at then
            local schedule_id, schedule_err = create_token_refresh_schedule(new_component_id, provider_name, connection_name, oauth_connection.expires_at)
            if schedule_id and not schedule_err then
                oauth_repo.update_schedule_id(new_component_id, schedule_id)
            end
        end

        return new_component_id
    end
end

local function run(args)
    if not args or not args.state_token or not args.connection_data or not args.connector_info then
        return
    end

    local state_token = args.state_token
    local connection_data = args.connection_data
    local connector_info = args.connector_info
    local provider_name = connection_data.provider_name

    -- Register process
    local registry_name = REGISTRY_PREFIX .. state_token
    local registered = process.registry.register(registry_name)
    if not registered then
        return
    end

    -- Set up channels
    local inbox = process.inbox()
    local timeout_channel = time.after(NEGOTIATION_TIMEOUT)

    -- Wait for callback or timeout
    local result = channel.select({
        inbox:case_receive(),
        timeout_channel:case_receive()
    })

    -- Always unregister
    process.registry.unregister(registry_name)

    if result.channel == timeout_channel then
        return
    end

    -- Handle callback
    local message = result.value
    local reply_to = message:from()

    local function send_response(response_data)
        if reply_to then
            process.send(reply_to, REPLY_TOPIC, response_data)
        end
    end

    if message:topic() ~= CALLBACK_TOPIC then
        return
    end

    local callback_data = message:payload():data()

    -- Validate callback data
    if not callback_data.code or not callback_data.state then
        send_response({
            success = false,
            error = "Invalid callback data"
        })
        return
    end

    if callback_data.state ~= state_token then
        send_response({
            success = false,
            error = "State token mismatch"
        })
        return
    end

    -- Check OAuth errors
    if callback_data.error then
        send_response({
            success = false,
            error = "OAuth provider error: " .. callback_data.error,
            oauth_error = true
        })
        return
    end

    -- Get OAuth contract
    local oauth_contract, err = contract.get(OAUTH_CONNECTOR_CONTRACT)
    if err then
        send_response({
            success = false,
            error = "Failed to get OAuth contract: " .. err
        })
        return
    end

    -- Open OAuth instance
    local oauth_instance, err = oauth_contract
        :with_context(connector_info.context_values)
        :open(connector_info.implementation_id :: string)
    if err then
        send_response({
            success = false,
            error = "Failed to open OAuth implementation: " .. err
        })
        return
    end

    -- Handle callback
    local callback_result, err = oauth_instance:handle_callback({
        code = callback_data.code,
        state = callback_data.state,
        stored_data = connection_data.oauth_data
    })

    if err then
        send_response({
            success = false,
            error = "OAuth callback failed: " .. err
        })
        return
    end

    if not callback_result.success then
        send_response({
            success = false,
            error = callback_result.error or "Token exchange failed",
            oauth_error = true
        })
        return
    end

    -- Register component
    local component_id, register_err = register_component(
        connection_data.component_id :: string,
        callback_result.oauth_connection,
        callback_result.user_context,
        provider_name,
        connection_data.connection_name,
        connection_data.connection_description
    )

    if register_err then
        send_response({
            success = false,
            error = register_err
        })
        return
    end

    -- Send success response
    send_response({
        success = true,
        component_id = component_id
    })
end

return { run = run }