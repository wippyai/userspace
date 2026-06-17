-- component: the client library for opening components with access validation.
-- It wraps the component_service contract (actor-validated paths) and the
-- component_reader (system-level paths). Every function returns (value, error?);
-- errors are structured via the global errors module and never raised.

local contract = require("contract")
local component_reader = require("component_reader")
local consts = require("userspace_component_consts")

-- Contract ids the client talks to.
local COMPONENT_SERVICE = "userspace.component:component_service"
local DEFAULT_CONTRACT = "userspace.contract:component"

-- Access level bitmask (re-exported so callers reference component.ACCESS.*).
local ACCESS = consts.ACCESS

-- An opened contract instance: its methods are dispatched by the contract.
type ContractInstance = any -- runtime contract proxy; method set is contract-defined

-- The component_service contract instance.
type ServiceInstance = any -- runtime contract proxy

-- Bitwise AND for access-mask checks (Lua 5.1 has no bit operators).
local function bitwise_and(a: integer, b: integer): integer
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

-- Open the component service contract.
local function get_component_service(): (ServiceInstance?, error?)
    local component_service_contract, err = contract.get(COMPONENT_SERVICE)
    if err then
        return nil, (errors.new({ message = "failed to get component service: " .. tostring(err), kind = errors.INTERNAL }) :: error)
    end

    local service, service_err = component_service_contract:open()
    if service_err then
        return nil, (errors.new({ message = "failed to open component service: " .. tostring(service_err), kind = errors.INTERNAL }) :: error)
    end

    return service :: ServiceInstance?, nil
end

-- Map a service result's {success,error} envelope into a structured error.
local function service_result_error(result: any, operation_name: string): error?
    if not result then
        return (errors.new({ message = operation_name .. " returned nil result", kind = errors.INTERNAL }) :: error)
    end
    if not result.success then
        return (errors.new({ message = result.error or (operation_name .. " failed"), kind = errors.PERMISSION_DENIED }) :: error)
    end
    return nil
end

-- Open a contract instance bound to impl_id with the component context.
local function open_contract_instance(impl_id: string, context: { [string]: any }, target_contract_id: string?): (ContractInstance?, error?)
    local contract_to_open = target_contract_id or DEFAULT_CONTRACT

    local target_contract, contract_err = contract.get(contract_to_open)
    if contract_err then
        return nil, (errors.new({ message = "failed to get contract '" .. contract_to_open .. "': " .. tostring(contract_err), kind = errors.INTERNAL }) :: error)
    end

    local instance, instance_err = target_contract:open(impl_id, context)
    if instance_err then
        return nil, (errors.new({ message = "failed to open component instance: " .. tostring(instance_err), kind = errors.INTERNAL }) :: error)
    end

    if target_contract_id and not contract.is(instance, target_contract_id) then
        return nil, (errors.new({ message = "component does not implement target contract '" .. tostring(target_contract_id) .. "'", kind = errors.INVALID }) :: error)
    end

    return instance :: ContractInstance?, nil
end

-- Public service accessor.
local function get_service(): (ServiceInstance?, error?)
    return get_component_service()
end

-- Resolve the actor's access context for a component via the service.
local function resolve_access_context(component_id: string): (any, error?)
    local service, service_err = get_component_service()
    if service_err or not service then
        return nil, service_err
    end

    local access_result, access_err = service:get_access_context({ component_id = component_id })
    if access_err then
        return nil, (errors.new({ message = "component not found or access denied: " .. tostring(access_err), kind = errors.NOT_FOUND }) :: error)
    end

    local result_err = service_result_error(access_result, "get_access_context")
    if result_err then
        return nil, result_err
    end

    return access_result, nil
end

-- Validate access to a component without opening it. Returns the actor's access
-- level when it satisfies required_access, else (0, error).
local function validate_access(component_id: string, required_access: integer): (integer, error?)
    if not component_id or component_id == "" then
        return 0, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end
    if not required_access or type(required_access) ~= "number" then
        return 0, (errors.new({ message = "access level is required", kind = errors.INVALID }) :: error)
    end

    local access_result, access_err = resolve_access_context(component_id)
    if access_err then
        return 0, access_err
    end

    local user_access = access_result.access_level or 0
    if bitwise_and(user_access, required_access) == required_access then
        return user_access, nil
    end
    return 0, (errors.new({ message = "insufficient access to component", kind = errors.PERMISSION_DENIED }) :: error)
end

-- Open a component by ID with access validation.
local function open(component_id: string, required_access: integer, target_contract_id: string?): (ContractInstance?, error?)
    if not component_id or component_id == "" then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end
    if not required_access or type(required_access) ~= "number" then
        return nil, (errors.new({ message = "access level is required", kind = errors.INVALID }) :: error)
    end

    local access_result, access_err = resolve_access_context(component_id)
    if access_err then
        return nil, access_err
    end

    local user_access = access_result.access_level or 0
    if bitwise_and(user_access, required_access) ~= required_access then
        return nil, (errors.new({ message = "insufficient access to component", kind = errors.PERMISSION_DENIED }) :: error)
    end

    local context = access_result.context or {}
    context.component_id = component_id

    return open_contract_instance(access_result.impl_id :: string, context, target_contract_id)
end

-- Validate that meta_filters is a non-empty string->string map.
local function validate_meta_filters(meta_filters: any): error?
    if not meta_filters or type(meta_filters) ~= "table" then
        return (errors.new({ message = "metadata filters are required and must be a table", kind = errors.INVALID }) :: error)
    end
    local has_filters = false
    for key, value in pairs(meta_filters) do
        if type(key) ~= "string" or type(value) ~= "string" then
            return (errors.new({ message = "metadata filters must be string key-value pairs", kind = errors.INVALID }) :: error)
        end
        has_filters = true
    end
    if not has_filters then
        return (errors.new({ message = "at least one metadata filter is required", kind = errors.INVALID }) :: error)
    end
    return nil
end

-- Resolve a single component's access context by metadata filters via the service.
local function resolve_access_context_by_meta(meta_filters: { [string]: string }, required_access: integer): (any, error?)
    local service, service_err = get_component_service()
    if service_err or not service then
        return nil, service_err
    end

    local access_result, access_err = service:get_access_context_by_meta({
        meta = meta_filters,
        access_mask = required_access,
    })
    if access_err then
        return nil, (errors.new({ message = tostring(access_err), kind = errors.NOT_FOUND }) :: error)
    end

    local result_err = service_result_error(access_result, "get_access_context_by_meta")
    if result_err then
        return nil, result_err
    end

    return access_result, nil
end

-- Find and open a single component by metadata filters.
local function open_by_meta(meta_filters: { [string]: string }, required_access: integer, target_contract_id: string?): (ContractInstance?, error?)
    local filters_err = validate_meta_filters(meta_filters)
    if filters_err then
        return nil, filters_err
    end
    if not required_access or type(required_access) ~= "number" then
        return nil, (errors.new({ message = "access level is required", kind = errors.INVALID }) :: error)
    end

    local access_result, access_err = resolve_access_context_by_meta(meta_filters, required_access)
    if access_err then
        return nil, access_err
    end

    return open_contract_instance(access_result.impl_id :: string, (access_result.context or {}) :: { [string]: any }, target_contract_id)
end

-- Get a component's private context by ID with access validation.
local function get_context(component_id: string, required_access: integer): ({ [string]: any }?, error?)
    if not component_id or component_id == "" then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end
    if not required_access or type(required_access) ~= "number" then
        return nil, (errors.new({ message = "access level is required", kind = errors.INVALID }) :: error)
    end

    local access_result, access_err = resolve_access_context(component_id)
    if access_err then
        return nil, access_err
    end

    local user_access = access_result.access_level or 0
    if bitwise_and(user_access, required_access) ~= required_access then
        return nil, (errors.new({ message = "insufficient access to component", kind = errors.PERMISSION_DENIED }) :: error)
    end

    local context = access_result.context or {}
    context.component_id = component_id
    return context, nil
end

-- Get a component's private context by metadata filters with access validation.
local function get_context_by_meta(meta_filters: { [string]: string }, required_access: integer): ({ [string]: any }?, error?)
    local filters_err = validate_meta_filters(meta_filters)
    if filters_err then
        return nil, filters_err
    end
    if not required_access or type(required_access) ~= "number" then
        return nil, (errors.new({ message = "access level is required", kind = errors.INVALID }) :: error)
    end

    local access_result, access_err = resolve_access_context_by_meta(meta_filters, required_access)
    if access_err then
        return nil, access_err
    end

    return (access_result.context or {}) :: { [string]: any }, nil
end

-- Get a component's private context by ID without actor validation. Reads
-- directly from the database, suitable for system-level / background workers.
local function get_private_context(component_id: string): ({ [string]: any }?, error?)
    if not component_id or component_id == "" then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end

    local result, read_err = component_reader.new()
        :with_components(component_id)
        :include_options({ private_context = true, meta = false })
        :one()
    if read_err then
        return nil, read_err
    end
    if not result then
        return nil, (errors.new({ message = "component not found", kind = errors.NOT_FOUND }) :: error)
    end

    local context = result.private_context or {}
    context.component_id = component_id
    return context, nil
end

-- Open a component by ID without actor validation. Reads impl_id and private
-- context directly from the database, then opens the contract instance.
-- Suitable for system-level / background workers.
local function open_private(component_id: string, target_contract_id: string?): (ContractInstance?, error?)
    if not component_id or component_id == "" then
        return nil, (errors.new({ message = "component ID is required", kind = errors.INVALID }) :: error)
    end

    local result, read_err = component_reader.new()
        :with_components(component_id)
        :include_options({ private_context = true, meta = false })
        :one()
    if read_err then
        return nil, read_err
    end
    if not result then
        return nil, (errors.new({ message = "component not found", kind = errors.NOT_FOUND }) :: error)
    end

    local context = result.private_context or {}
    context.component_id = component_id

    return open_contract_instance(result.impl_id :: string, context, target_contract_id)
end

return {
    ACCESS = ACCESS,
    open = open,
    open_by_meta = open_by_meta,
    open_private = open_private,
    validate_access = validate_access,
    get_service = get_service,
    get_context = get_context,
    get_context_by_meta = get_context_by_meta,
    get_private_context = get_private_context,
}
