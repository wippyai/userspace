local http = require("http")
local json = require("json")
local component = require("component")

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
    if not request_data.content or request_data.content == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Content is required"
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

    -- Prepare embed request
    local embed_request = {
        content = request_data.content,
        content_type = request_data.content_type or "text/plain",
        metadata = request_data.metadata or {}
    }

    -- Embed content
    local result, embed_err = kb9_instance:embed_content(embed_request)
    if embed_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to embed content: " .. embed_err
        })
        return
    end

    print(result.success)

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
        success = true,
        ops_executed = result.ops_executed or 0
    })
end

return {
    handler = handler
}