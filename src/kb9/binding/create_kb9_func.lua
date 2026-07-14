local uuid = require("uuid")
local time = require("time")
local component = require("component")
local store = require("store")
local consts = require("consts")

local function handle(request_dto)
    -- Validate request
    if not request_dto or type(request_dto) ~= "table" then
        return {
            success = false,
            error = { code = "INVALID_REQUEST", message = "Request must be a table" }
        }
    end

    if not request_dto.name or type(request_dto.name) ~= "string" or request_dto.name:gsub("%s+", "") == "" then
        return {
            success = false,
            error = { code = "INVALID_NAME", message = "Name is required and must be a non-empty string" }
        }
    end

    if not request_dto.config or type(request_dto.config) ~= "table" then
        return {
            success = false,
            error = { code = "INVALID_CONFIG", message = "Config is required and must be a table" }
        }
    end

    if not request_dto.config.embed_contract then
        return {
            success = false,
            error = { code = "MISSING_EMBED_CONTRACT", message = "Embed contract configuration is required" }
        }
    end

    if not request_dto.config.query_contract then
        return {
            success = false,
            error = { code = "MISSING_QUERY_CONTRACT", message = "Query contract configuration is required" }
        }
    end

    if not request_dto.embedding_model or type(request_dto.embedding_model) ~= "string" or request_dto.embedding_model:gsub("%s+", "") == "" then
        return {
            success = false,
            error = { code = "MISSING_EMBEDDING_MODEL", message = "Embedding model is required and must be a non-empty string" }
        }
    end

    -- Generate component ID
    local component_id = uuid.v7()

    -- Get component service
    local service, err = component.get_service()
    if err then
        return {
            success = false,
            error = { code = "SERVICE_ERROR", message = "Failed to get component service: " .. err }
        }
    end

    -- Create KB9 component in persistence layer first
    local kb9_config = {
        embedding_model = request_dto.embedding_model,
        embed_contract = request_dto.config.embed_contract,
        query_contract = request_dto.config.query_contract
    }

    local create_result, create_err = store(component_id)
        :component():create(kb9_config)
        :execute()

    if create_err then
        return {
            success = false,
            error = { code = "STORE_ERROR", message = "Failed to create KB9 component: " .. create_err }
        }
    end

    -- Register component in userspace
    local register_request = {
        component_id = component_id,
        impl_id = consts.COMPONENT.IMPL_ID,
        meta = {
            title = request_dto.name,
            description = request_dto.description or consts.COMPONENT.DEFAULT_DESCRIPTION,
            class = consts.COMPONENT.CLASS,
            type = consts.COMPONENT.TYPE
        },
        private_context = { component_id = component_id }
    }

    local register_result, register_err = service:register_component(register_request)
    if register_err then
        -- Cleanup KB9 component if registration fails
        store(component_id):component():delete():execute()

        return {
            success = false,
            error = { code = "REGISTER_ERROR", message = "Failed to register component: " .. register_err }
        }
    end

    if not register_result.success then
        -- Cleanup KB9 component if registration fails
        store(component_id):component():delete():execute()

        return {
            success = false,
            error = register_result.error or { code = "REGISTER_FAILED", message = "Component registration failed" }
        }
    end

    -- Send initialization commands to KB9 root service as a single array
    local current_pid = process.pid()
    local ack_responses = process.listen(consts.MESSAGE_TOPICS.KB_ASK)

    -- Build commands array
    local commands = {
        {
            type = consts.COMMAND_TYPES.INIT_EMBED,
            payload = {
                embed_contract = request_dto.config.embed_contract
            }
        },
        {
            type = consts.COMMAND_TYPES.INIT_QUERY,
            payload = {
                query_contract = request_dto.config.query_contract
            }
        }
    }

    local init_cmd = {
        component_id = component_id,
        commands = commands,
        reply_to = current_pid
    }

    local ok, err = process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_COMMAND, init_cmd)
    if not ok then
        print("Warning: Failed to send initialization commands:", err)
        return {
            success = true,
            component_id = component_id,
            name = request_dto.name,
            description = request_dto.description or consts.COMPONENT.DEFAULT_DESCRIPTION,
            config = request_dto.config,
            created_at = register_result.created_at,
            initialization = {
                commands_sent = 0,
                init_success = false,
                errors = {"Failed to send initialization commands: " .. (err or "unknown error")}
            }
        }
    end

    print("Sent initialization commands to KB9 root service for component:", component_id)

    -- Wait for acknowledgments from both commands
    local init_success = true
    local init_errors = {}
    local expected_acks = #commands
    local acks_received = 0
    local timeout = time.after(consts.ASK_TIMEOUT)

    while acks_received < expected_acks do
        local result = channel.select({
            ack_responses:case_receive(),
            timeout:case_receive()
        })

        if result.channel == timeout then
            table.insert(init_errors, "Timeout waiting for initialization acknowledgments")
            init_success = false
            break
        end

        local ack = result.value
        acks_received = acks_received + 1

        if ack.startup_error then
            table.insert(init_errors, "KB startup failed: " .. (ack.error or "unknown error"))
            init_success = false
        elseif not ack.success then
            table.insert(init_errors, "Command failed: " .. (ack.error or "unknown error"))
            init_success = false
        end
    end

    local response = {
        success = true,
        component_id = component_id,
        name = request_dto.name,
        description = request_dto.description or consts.COMPONENT.DEFAULT_DESCRIPTION,
        config = request_dto.config,
        created_at = register_result.created_at,
        initialization = {
            commands_sent = #commands,
            init_success = init_success
        }
    }

    if #init_errors > 0 then
        response.initialization.errors = init_errors
    end

    return response
end

return { handle = handle }
