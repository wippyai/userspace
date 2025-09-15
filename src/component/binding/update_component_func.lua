local sql = require("sql")
local security = require("security")
local ops = require("ops")

-- Constants
local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_COMPONENT_ID = "component_id is required and must be a non-empty string",
    MISSING_COMMANDS = "commands is required and must be a non-empty array",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID"
}

local COMMAND_ERRORS = {
    INVALID_COMMAND = "must be a table",
    MISSING_TYPE = ".type is required and must be a string",
    MISSING_PAYLOAD = ".payload is required and must be a table",
    UNSUPPORTED_TYPE = ".type '%s' is not supported"
}

local DATABASE_ERRORS = {
    CONNECTION_FAILED = "Failed to connect to database",
    TRANSACTION_FAILED = "Failed to begin transaction",
    ACCESS_DENIED = "Insufficient access to perform requested operations",
    NO_HANDLER = "No handler found for command type",
    COMMAND_FAILED = "Command %d failed",
    COMMIT_FAILED = "Failed to commit transaction"
}

-- Supported command types and their required access levels
local COMMAND_ACCESS_REQUIREMENTS = {
    [ops.COMMAND_TYPES.PUT_META] = ops.ACCESS.WRITE,
    [ops.COMMAND_TYPES.DELETE_META] = ops.ACCESS.WRITE,
    [ops.COMMAND_TYPES.GRANT_ACCESS] = ops.ACCESS.ADMIN,
    [ops.COMMAND_TYPES.REVOKE_ACCESS] = ops.ACCESS.ADMIN
}

---Helper function for bitwise OR operation
---@param a integer First number
---@param b integer Second number
---@return integer result Bitwise OR result
local function bitwise_or(a, b)
    local result = 0
    local bit = 1
    while bit <= math.max(a, b) do
        if (a % (bit * 2) >= bit) or (b % (bit * 2) >= bit) then
            result = result + bit
        end
        bit = bit * 2
    end
    return result
end

local function validate_commands(commands)
    local required_access = 0

    for i, command in ipairs(commands) do
        -- Validate command structure
        if type(command) ~= "table" then
            return nil, "commands[" .. i .. "] " .. COMMAND_ERRORS.INVALID_COMMAND
        end

        if not command.type or type(command.type) ~= "string" then
            return nil, "commands[" .. i .. "]" .. COMMAND_ERRORS.MISSING_TYPE
        end

        if not command.payload or type(command.payload) ~= "table" then
            return nil, "commands[" .. i .. "]" .. COMMAND_ERRORS.MISSING_PAYLOAD
        end

        -- Check if command type is supported and get access requirements
        local access_required = COMMAND_ACCESS_REQUIREMENTS[command.type]
        if not access_required then
            return nil, "commands[" .. i .. "]" .. string.format(COMMAND_ERRORS.UNSUPPORTED_TYPE, command.type)
        end

        -- Accumulate required access permissions using bitwise OR
        required_access = bitwise_or(required_access, access_required)
    end

    return required_access, nil
end

local function handle(request_dto)
    -- Input validation
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.component_id or type(request_dto.component_id) ~= "string" or request_dto.component_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    if not request_dto.commands or type(request_dto.commands) ~= "table" or #request_dto.commands == 0 then
        return { success = false, error = VALIDATION_ERRORS.MISSING_COMMANDS }
    end

    -- Security context validation
    local actor = security.actor()
    if not actor then
        return { success = false, error = VALIDATION_ERRORS.NO_ACTOR }
    end

    local user_id = actor:id()
    if not user_id or user_id == "" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_ACTOR }
    end

    -- Validate commands and determine required access level
    local required_access, validate_error = validate_commands(request_dto.commands)
    if validate_error then
        return { success = false, error = validate_error }
    end

    -- Database transaction
    local db, err_db = sql.get(ops.DB_RESOURCE)
    if err_db then
        return { success = false, error = DATABASE_ERRORS.CONNECTION_FAILED .. ": " .. err_db }
    end

    local tx, err_tx = db:begin()
    if err_tx then
        db:release()
        return { success = false, error = DATABASE_ERRORS.TRANSACTION_FAILED .. ": " .. err_tx }
    end

    -- Check user access to component
    local has_access = ops.check_user_access(tx, user_id, request_dto.component_id, required_access)
    if not has_access then
        tx:rollback()
        db:release()
        return { success = false, error = DATABASE_ERRORS.ACCESS_DENIED }
    end

    -- Execute each command in sequence
    local results = {}
    local changes_made = false

    for i, command in ipairs(request_dto.commands) do
        -- Prepare command payload with component_id
        local command_payload = {}
        for k, v in pairs(command.payload) do
            command_payload[k] = v
        end
        command_payload.component_id = request_dto.component_id

        local command_to_execute = {
            type = command.type,
            payload = command_payload
        }

        -- Execute command using ops handler
        local handler = ops.handlers[command.type]
        if not handler then
            tx:rollback()
            db:release()
            return { success = false, error = DATABASE_ERRORS.NO_HANDLER .. ": " .. command.type }
        end

        local result, err_cmd = handler(tx, command_to_execute)
        if err_cmd then
            tx:rollback()
            db:release()
            return { success = false, error = string.format(DATABASE_ERRORS.COMMAND_FAILED, i) .. ": " .. err_cmd }
        end

        table.insert(results, result)
        if result and result.changes_made then
            changes_made = true
        end
    end

    -- Commit transaction
    local commit_ok, err_commit = tx:commit()
    if err_commit then
        tx:rollback()
        db:release()
        return { success = false, error = DATABASE_ERRORS.COMMIT_FAILED .. ": " .. err_commit }
    end

    db:release()

    -- Success response
    return {
        component_id = request_dto.component_id,
        changes_made = changes_made,
        results = results,
        success = true,
        updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    }
end

return { handle = handle }