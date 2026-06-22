local http = require("http")
local json = require("json")
local contract = require("contract")
local api_error = require("api_error")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Set JSON content type
    res:set_content_type(http.CONTENT.JSON)

    -- Only allow GET requests
    if req:method() ~= "GET" then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:write_json({
            success = false,
            error = "Method not allowed. Use GET."
        })
        return
    end

    -- Parse query parameters for filtering
    local filters = {}

    -- Get groups filter from query params
    local groups_param = req:query("groups")
    if groups_param and groups_param ~= "" then
        -- Support comma-separated groups
        local groups = {}
        for group in groups_param:gmatch("[^,]+") do
            table.insert(groups, group:match("^%s*(.-)%s*$")) -- trim whitespace
        end
        if #groups > 0 then
            filters.groups = groups
        end
    end

    -- Get classes filter from query params
    local classes_param = req:query("classes")
    if classes_param and classes_param ~= "" then
        -- Support comma-separated classes
        local classes = {}
        for class in classes_param:gmatch("[^,]+") do
            table.insert(classes, class:match("^%s*(.-)%s*$")) -- trim whitespace
        end
        if #classes > 0 then
            filters.classes = classes
        end
    end

    -- Get discovery service
    local discovery_service, err = contract.get("userspace.credentials.discovery:provider_discovery")
    if not discovery_service then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Discovery service not available", err)
        return
    end

    -- Open service instance
    local service, err = discovery_service:open()
    if not service then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to open discovery service", err)
        return
    end

    -- Call discovery service
    local request_dto = {}
    if next(filters) then -- Check if filters table is not empty
        request_dto.filters = filters
    end

    local result, err = service:list_available_providers(request_dto)

    if not result then
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Service call failed", err)
        return
    end

    -- Check for service errors
    if not result.success then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = result.error or "Failed to discover credential providers"
        })
        return
    end

    -- Return the service response directly
    local response = {
        success = true,
        providers = result.providers,
        total_count = result.total_count,
        available_groups = result.available_groups,
        available_classes = result.available_classes
    }

    res:set_status(http.STATUS.OK)
    res:write_json(response)
end

return {
    handler = handler
}