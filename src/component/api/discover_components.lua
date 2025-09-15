local http = require("http")
local json = require("json")
local contract = require("contract")

-- Constants
local DISCOVERY_SERVICE_CONTRACT = "userspace.component.discovery:component_discovery"

local function handler()
    -- Get response and request objects
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Get discovery service contract
    local discovery_service, err = contract.get(DISCOVERY_SERVICE_CONTRACT)
    if not discovery_service then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to get discovery service: " .. (err or "unknown error")
        })
        return
    end

    -- Open the service (uses default binding)
    local service, err = discovery_service:open()
    if not service then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to open discovery service: " .. (err or "unknown error")
        })
        return
    end

    -- Parse query parameters
    local class = req:query("class")
    local namespace = req:query("namespace")
    local search = req:query("search")
    local include_ui = req:query("include_ui")

    -- Validate include_ui parameter
    local include_ui_bindings = true -- Default to true
    if include_ui == "false" or include_ui == "0" then
        include_ui_bindings = false
    end

    -- Build request DTO
    local request_dto = {
        include_ui_bindings = include_ui_bindings
    }

    -- Add filters if provided
    local filters = {}

    if class and class ~= "" then
        filters.classes = { class }
    end

    if namespace and namespace ~= "" then
        filters.namespaces = { namespace }
    end

    if search and search ~= "" then
        filters.search = search
    end

    if next(filters) then
        request_dto.filters = filters
    end

    -- Call the discovery service
    local result, err = service:list_available_components(request_dto)
    if not result then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Service call failed: " .. (err or "unknown error")
        })
        return
    end

    -- Check if service returned an error
    if not result.success then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = result.error or "Service returned error"
        })
        return
    end

    -- Return successful response
    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        count = #result.components,
        total = result.total_count,
        available_classes = result.available_classes,
        components = result.components,
        filters = {
            class = class,
            namespace = namespace,
            search = search,
            include_ui = include_ui_bindings
        }
    })
end

return {
    handler = handler
}