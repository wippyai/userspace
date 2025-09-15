local http = require("http")
local json = require("json")
local component = require("component")
local contract = require("contract")

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
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    if req:method() ~= http.METHOD.PUT then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Method not allowed. Use PUT."
        })
        return
    end

    -- Get component ID from path parameter
    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing required path parameter: component_id"
        })
        return
    end

    -- Parse request body
    local body_str = req:body()
    if not body_str or body_str == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Request body is required"
        })
        return
    end

    local update_data, decode_err = json.decode(body_str)
    if decode_err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Invalid JSON in request body: " .. decode_err
        })
        return
    end

    -- Pre-validate embed contract options if provided
    if update_data.embed_contract then
        if not update_data.embed_contract.binding_id then
            res:set_status(http.STATUS.BAD_REQUEST)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Missing required field: embed_contract.binding_id"
            })
            return
        end

        local embed_valid, embed_err = validate_implementation_options(
            update_data.embed_contract.binding_id,
            "userspace.kb9:kb9_embed_contract",
            update_data.embed_contract.options
        )

        if not embed_valid then
            res:set_status(http.STATUS.BAD_REQUEST)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Embed contract validation failed: " .. (embed_err or "unknown error")
            })
            return
        end
    end

    -- Pre-validate query contract options if provided
    if update_data.query_contract then
        if not update_data.query_contract.binding_id then
            res:set_status(http.STATUS.BAD_REQUEST)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Missing required field: query_contract.binding_id"
            })
            return
        end

        local query_valid, query_err = validate_implementation_options(
            update_data.query_contract.binding_id,
            "userspace.kb9:kb9_query_contract",
            update_data.query_contract.options
        )

        if not query_valid then
            res:set_status(http.STATUS.BAD_REQUEST)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Query contract validation failed: " .. (query_err or "unknown error")
            })
            return
        end
    end

    -- Open KB9 component (access validation happens here)
    local kb9_instance, kb9_err = component.open(component_id, component.ACCESS.WRITE, "userspace.kb9:kb9_contract")
    if not kb9_instance then
        local status_code = http.STATUS.INTERNAL_ERROR
        if kb9_err and kb9_err:find("not found") then
            status_code = http.STATUS.NOT_FOUND
        elseif kb9_err and (kb9_err:find("access denied") or kb9_err:find("Insufficient access")) then
            status_code = http.STATUS.FORBIDDEN
        end

        res:set_status(status_code)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = kb9_err or "Failed to open KB9 component"
        })
        return
    end

    -- Update config
    local result, update_err = kb9_instance:update_config(update_data)
    if update_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to update KB9 config: " .. update_err
        })
        return
    end

    if not result.success then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json(result)
        return
    end

    -- Return success response
    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true
    })
end

return {
    handler = handler
}