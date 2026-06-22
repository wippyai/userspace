local http = require("http")
local json = require("json")
local contract = require("contract")
local api_error = require("api_error")

local function validate_implementation_options(binding_id, target_contract, options)
    -- Get the target contract definition (embed or query)
    local contract_def, contract_err = contract.get(target_contract)
    if contract_err then
        return false, "Failed to get contract " .. target_contract .. ": " .. contract_err
    end

    -- Open the specific implementation with target contract
    local impl_instance, impl_err = contract_def:open(binding_id)
    if impl_err then
        return false, "Failed to open implementation " .. binding_id .. ": " .. impl_err
    end

    -- Check if the instance ALSO implements the validate contract
    if not contract.is(impl_instance, "userspace.kb9:kb9_validate_contract") then
        -- Skip validation if the binding doesn't implement validate contract
        return true, nil
    end

    -- Validate options since it implements validate contract
    local validation_result, validation_err = impl_instance:validate_options({
        options = options or {}
    })

    if validation_err then
        return false, "Validation failed for " .. binding_id .. ": " .. validation_err
    end

    if not validation_result.valid then
        local error_msg = "Invalid options for " .. binding_id
        if validation_result.error and validation_result.error.message then
            error_msg = error_msg .. ": " .. validation_result.error.message
        end
        return false, error_msg
    end

    return true, nil
end

local function handler()
    -- Get request and response objects
    local req = http.request()
    local res = http.response()
    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    -- Parse request body
    local body_str = req:body()
    if not body_str or body_str == "" then
        res:set_content_type(http.CONTENT.JSON)
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Request body is required"
        })
        return
    end

    local success, request_data = pcall(json.decode, body_str)
    if not success then
        res:set_content_type(http.CONTENT.JSON)
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Invalid JSON in request body"
        })
        return
    end

    -- Validate that we have the required config structure
    if not request_data.config then
        res:set_content_type(http.CONTENT.JSON)
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing required field: config"
        })
        return
    end

    if not request_data.config.embed_contract or not request_data.config.embed_contract.binding_id then
        res:set_content_type(http.CONTENT.JSON)
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing required field: config.embed_contract.binding_id"
        })
        return
    end

    if not request_data.config.query_contract or not request_data.config.query_contract.binding_id then
        res:set_content_type(http.CONTENT.JSON)
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Missing required field: config.query_contract.binding_id"
        })
        return
    end

    -- Pre-validate embed contract options
    local embed_valid, embed_err = validate_implementation_options(
        request_data.config.embed_contract.binding_id,
        "userspace.kb9:kb9_embed_contract",
        request_data.config.embed_contract.options
    )

    if not embed_valid then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.BAD_REQUEST, "Embed contract validation failed", embed_err)
        return
    end

    -- Pre-validate query contract options
    local query_valid, query_err = validate_implementation_options(
        request_data.config.query_contract.binding_id,
        "userspace.kb9:kb9_query_contract",
        request_data.config.query_contract.options
    )

    if not query_valid then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.BAD_REQUEST, "Query contract validation failed", query_err)
        return
    end

    -- Get KB service contract
    local kb_service_contract, contract_err = contract.get("userspace.kb9:kb_service_contract")
    if contract_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get KB service contract", contract_err)
        return
    end

    -- Open the service instance (will use default binding userspace.kb9.bindings:kb_service)
    local kb_service, service_err = kb_service_contract:open()
    if service_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to open KB service", service_err)
        return
    end

    -- Call the create_kb9 method through the contract
    local result, call_err = kb_service:create_kb9(request_data)
    if call_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to create KB9", call_err)
        return
    end

    -- Check if the service returned an error
    if not result.success then
        res:set_content_type(http.CONTENT.JSON)
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json(result)
        return
    end

    -- Return success response
    res:set_content_type(http.CONTENT.JSON)
    res:set_status(http.STATUS.OK)
    res:write_json(result)
end

return {
    handler = handler
}