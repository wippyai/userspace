local contract = require("contract")

-- Constants
local COMPONENT_SERVICE = "userspace.component:component_service"
local DEFAULT_CONTRACT = "userspace.contract:component"

-- Access level constants (bitmask permissions)
local ACCESS = {
    NONE = 0,   -- 0000 - No access
    READ = 1,   -- 0001 - Can read component metadata
    WRITE = 2,  -- 0010 - Can modify component metadata
    DELETE = 4, -- 0100 - Can delete component
    ADMIN = 8,  -- 1000 - Full admin access (grant/revoke permissions)

    -- Common combinations
    READ_WRITE = 3,   -- 0011 - Read and write
    READ_DELETE = 5,  -- 0101 - Read and delete
    WRITE_DELETE = 6, -- 0110 - Write and delete
    FULL = 15,        -- 1111 - All permissions
}

---@class ComponentInstance
---@field [string] function Contract method calls

---@alias AccessLevel integer Access level bitmask

-- Helper Functions

---Helper function for bitwise AND operation
---@param a integer First number
---@param b integer Second number
---@return integer result Bitwise AND result
local function bitwise_and(a, b)
    local result = 0
    local bit = 1
    while bit <= math.max(a, b) do
        if (a % (bit * 2) >= bit) and (b % (bit * 2) >= bit) then
            result = result + bit
        end
        bit = bit * 2
    end
    return result
end

---Get component service instance
---@return table|nil service Component service instance or nil on error
---@return string|nil error Error message or nil on success
local function get_component_service()
    local component_service_contract, err = contract.get(COMPONENT_SERVICE)
    if err then
        return nil, "Failed to get component service: " .. err
    end

    local component_service, service_err = component_service_contract:open()
    if service_err then
        return nil, "Failed to open component service: " .. service_err
    end

    return component_service, nil
end

---Check service result for errors
---@param result table Service result
---@param operation_name string Name of operation for error messages
---@return string|nil error Error message or nil if success
local function check_service_result(result, operation_name)
    if not result then
        return operation_name .. " returned nil result"
    end

    if not result.success then
        return (result.error) or (operation_name .. " failed")
    end

    return nil
end

---Open contract instance with component context
---@param impl_id string Implementation ID to use as binding
---@param context table Component context
---@param target_contract_id string|nil Optional target contract ID
---@return ComponentInstance|nil instance Contract instance or nil on error
---@return string|nil error Error message or nil on success
local function open_contract_instance(impl_id, context, target_contract_id)
    local contract_to_open = target_contract_id or DEFAULT_CONTRACT

    local target_contract, contract_err = contract.get(contract_to_open)
    if contract_err then
        return nil, "Failed to get contract '" .. contract_to_open .. "': " .. contract_err
    end

    local instance, instance_err = target_contract:open(impl_id, context)
    if instance_err then
        return nil, "Failed to open component instance: " .. instance_err
    end

    -- Validate target contract if specified
    if target_contract_id and not contract.is(instance, target_contract_id) then
        return nil, "Component does not implement target contract '" .. target_contract_id .. "'"
    end

    return instance, nil
end

-- Public API Functions

---Get component service instance (public API)
---@return table|nil service Component service instance or nil on error
---@return string|nil error Error message or nil on success
local function get_service()
    return get_component_service()
end

---Validate access to a component without opening it
---@param component_id string Component UUID to check
---@param required_access AccessLevel Required access level bitmask
---@return integer access_level User's access level if they have required access, 0 if insufficient or error
---@return string|nil error Error message or nil on success
local function validate_access(component_id, required_access)
    if not component_id or component_id == "" then
        return 0, "Component ID is required"
    end

    if not required_access or type(required_access) ~= "number" then
        return 0, "Access level is required"
    end

    local component_service, service_err = get_component_service()
    if service_err then
        return 0, service_err
    end

    -- Get access context to check permissions
    local access_result, access_err = component_service:get_access_context({
        component_id = component_id
    })
    if access_err then
        return 0, "Component not found or access denied: " .. access_err
    end

    -- Check service result success
    local result_err = check_service_result(access_result, "get_access_context")
    if result_err then
        return 0, "Component not found or access denied: " .. result_err
    end

    -- Check access level using bitwise AND
    local user_access = access_result.access_level or 0
    local has_required_access = bitwise_and(user_access, required_access) == required_access

    if has_required_access then
        return user_access, nil
    else
        return 0, "Insufficient access to component"
    end
end

---Open a component by ID with access validation
---@param component_id string Component UUID to open
---@param required_access AccessLevel Required access level bitmask
---@param target_contract_id string|nil Optional target contract ID, uses default if nil
---@return ComponentInstance|nil instance Opened component instance or nil on error
---@return string|nil error Error message or nil on success
local function open(component_id, required_access, target_contract_id)
    if not component_id or component_id == "" then
        return nil, "Component ID is required"
    end

    if not required_access or type(required_access) ~= "number" then
        return nil, "Access level is required"
    end

    local component_service, service_err = get_component_service()
    if service_err then
        return nil, service_err
    end

    -- Get access context (includes impl_id - only one call needed!)
    local access_result, access_err = component_service:get_access_context({
        component_id = component_id
    })
    if access_err then
        return nil, "Component not found or access denied: " .. access_err
    end

    -- Check service result success
    local result_err = check_service_result(access_result, "get_access_context")
    if result_err then
        return nil, "Component not found or access denied: " .. result_err
    end

    -- Check access level using bitwise AND
    local user_access = access_result.access_level or 0
    local has_required_access = bitwise_and(user_access, required_access) == required_access

    if not has_required_access then
        return nil, "Insufficient access to component"
    end

    -- Prepare context with component_id
    local context = access_result.context or {}
    context.component_id = component_id

    -- Open the contract instance
    return open_contract_instance(access_result.impl_id, context, target_contract_id)
end

---Find and open a single component by metadata filters
---@param meta_filters table<string, string> Metadata key-value pairs to match (all must match)
---@param required_access AccessLevel Required access level bitmask
---@param target_contract_id string|nil Optional target contract ID, uses default if nil
---@return ComponentInstance|nil instance Opened component instance or nil on error
---@return string|nil error Error message or nil on success
local function open_by_meta(meta_filters, required_access, target_contract_id)
    -- Input validation
    if not meta_filters or type(meta_filters) ~= "table" then
        return nil, "Metadata filters are required and must be a table"
    end

    if not required_access or type(required_access) ~= "number" then
        return nil, "Access level is required"
    end

    -- Check if meta_filters is empty and validate types
    local has_filters = false
    for key, value in pairs(meta_filters) do
        if type(key) ~= "string" or type(value) ~= "string" then
            return nil, "Metadata filters must be string key-value pairs"
        end
        has_filters = true
    end

    if not has_filters then
        return nil, "At least one metadata filter is required"
    end

    local component_service, service_err = get_component_service()
    if service_err then
        return nil, service_err
    end

    -- Get access context by metadata (includes uniqueness check and impl_id)
    local access_result, access_err = component_service:get_access_context_by_meta({
        meta = meta_filters,
        access_mask = required_access
    })
    if access_err then
        return nil, access_err
    end

    -- Check service result success
    local result_err = check_service_result(access_result, "get_access_context_by_meta")
    if result_err then
        return nil, result_err
    end

    -- Open the contract instance
    return open_contract_instance(access_result.impl_id, access_result.context, target_contract_id)
end

-- Component module
local component = {
    ACCESS = ACCESS,
    open = open,
    open_by_meta = open_by_meta,
    validate_access = validate_access,
    get_service = get_service
}

return component