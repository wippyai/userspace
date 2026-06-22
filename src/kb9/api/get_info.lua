local http = require("http")
local json = require("json")
local component = require("component")
local api_error = require("api_error")

-- Access level descriptions
local ACCESS_DESCRIPTIONS = {
    [0] = "No Access",
    [1] = "Read Only",
    [2] = "Write Only",
    [3] = "Read & Write",
    [4] = "Delete Only",
    [5] = "Read & Delete",
    [6] = "Write & Delete",
    [7] = "Read, Write & Delete",
    [8] = "Admin Only",
    [9] = "Admin & Read",
    [10] = "Admin & Write",
    [11] = "Admin, Read & Write",
    [12] = "Admin & Delete",
    [13] = "Admin, Read & Delete",
    [14] = "Admin, Write & Delete",
    [15] = "Full Access (Owner)"
}

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    if req:method() ~= http.METHOD.GET then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Method not allowed. Use GET."
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

    -- Validate access and get access level
    local access_level, access_err = component.validate_access(component_id, component.ACCESS.READ)
    if not access_level then
        local status_code = http.STATUS.INTERNAL_ERROR
        if access_err and access_err:find("not found") then
            status_code = http.STATUS.NOT_FOUND
        elseif access_err and (access_err:find("access denied") or access_err:find("Insufficient access")) then
            status_code = http.STATUS.FORBIDDEN
        end

        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, status_code, "Failed to validate access", access_err)
        return
    end

    -- Get component service to fetch component metadata
    local service, service_err = component.get_service()
    if service_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get component service", service_err)
        return
    end

    -- Get component metadata (title, description, etc.)
    local component_info, component_err = service:get_component({
        component_id = component_id
    })
    if component_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get component info", component_err)
        return
    end

    -- Open KB9 component to get config
    local kb9_instance, kb9_err = component.open(component_id, component.ACCESS.READ, "userspace.kb9:kb9_contract")
    if not kb9_instance then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to open KB9 component", kb9_err)
        return
    end

    -- Get config from KB9
    local config_result, config_err = kb9_instance:get_config()
    if config_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get KB9 config", config_err)
        return
    end

    if not config_result.success then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = config_result.error and config_result.error.message or "Failed to get KB9 config"
        })
        return
    end

    -- Extract embedding model from config
    local embedding_model = "Unknown"
    if config_result.embedding_model then
        embedding_model = config_result.embedding_model
    end

    -- Combine component metadata with KB9 config
    local response = {
        success = true,
        -- Basic info
        name = component_info.meta.title or "Untitled KB9 Knowledge Base",
        description = component_info.meta.description or "",
        created_at = component_info.created_at,
        updated_at = component_info.updated_at,
        -- Access information
        access_level = access_level,
        access_description = ACCESS_DESCRIPTIONS[access_level] or "Unknown Access",
        -- Component reference info
        implementation_id = component_info.impl_id,
        -- KB9 configuration (single source of truth)
        config = {
            embedding_model = embedding_model,
            embed_contract = config_result.embed_contract,
            query_contract = config_result.query_contract
        },
        -- TODO: Add actual record count when we have node counting
        record_count = 0
    }

    -- Return successful response
    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json(response)
end

return {
    handler = handler
}