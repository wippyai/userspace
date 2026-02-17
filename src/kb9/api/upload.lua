local http = require("http")
local json = require("json")
local uuid = require("uuid")
local component = require("component")
local consts = require("userspace_consts")
local operations_repo = require("userspace_operations_repo")
local security = require("security")

local CONTENT_PROVIDER_BINDING_ID = "userspace.uploads:content_provider"

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    if req:method() ~= http.METHOD.POST then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Method not allowed. Use POST."
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

    local request_data, decode_err = json.decode(body_str)
    if decode_err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Invalid JSON in request body: " .. decode_err
        })
        return
    end

    -- Validate required fields
    if not request_data.upload_uuid or request_data.upload_uuid == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "upload_uuid is required"
        })
        return
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

    local operation_id = uuid.v7()

    local _, create_err = operations_repo.create({
        id = operation_id,
        component_id = component_id,
        upload_uuid = request_data.upload_uuid,
        status = consts.OPERATION_STATUS.PROCESSING
    })

    if create_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to create operation record: " .. create_err
        })
        return
    end

    local commands = {
        {
            type = consts.COMMAND_TYPES.EMBED_REFERENCE,
            payload = {
                reference = {
                    binding_id = CONTENT_PROVIDER_BINDING_ID,
                    context = {
                        upload_id = request_data.upload_uuid
                    }
                },
                metadata = request_data.metadata or {},
                operation_id = operation_id,
                uploaded_by = security.actor():id()
            }
        }
    }

    local command_msg = {
        component_id = component_id,
        commands = commands,
        reply_to = consts.PROCESS_NAMES.ROOT_SERVICE
    }

    local ok, send_err = process.send(consts.PROCESS_NAMES.ROOT_SERVICE, consts.MESSAGE_TOPICS.KB_COMMAND, command_msg)
    if not ok then
        operations_repo.update_status(operation_id, consts.OPERATION_STATUS.FAILED, 0, "Failed to send command: " .. (send_err or "unknown error"))

        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to send embed command: " .. (send_err or "unknown error")
        })
        return
    end

    res:set_status(http.STATUS.ACCEPTED)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        operation_id = operation_id,
        status = consts.OPERATION_STATUS.PROCESSING
    })
end

return {
    handler = handler
}
