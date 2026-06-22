local http = require("http")
local json = require("json")
local component = require("component")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local service, err = component.get_service()
    if err or not service then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({ success = false, error = "Failed to get component service: " .. tostring(err) })
        return
    end

    local limit = tonumber(req:query("limit")) or 50
    local offset = tonumber(req:query("offset")) or 0
    local impl_id = req:query("impl_id")
    local class = req:query("class")
    local access_mask = tonumber(req:query("access_mask"))

    if limit < 1 or limit > 100 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({ success = false, error = "limit must be between 1 and 100" })
        return
    end

    if offset < 0 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({ success = false, error = "offset must be >= 0" })
        return
    end

    local request_dto = {
        pagination = { limit = limit, offset = offset }
    }

    local filters = {}
    if impl_id and impl_id ~= "" then
        filters.impl_ids = { impl_id }
    end
    if class and class ~= "" then
        filters.meta = { class = class }
    end
    if access_mask and access_mask > 0 then
        filters.access_mask = access_mask
    end
    if next(filters) then
        request_dto.filters = filters
    end

    local result, call_err = service:list_components(request_dto)
    if not result then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({ success = false, error = "Service call failed: " .. (call_err or "unknown error") })
        return
    end

    if not result.success then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({ success = false, error = result.error or "Service returned error" })
        return
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        count = #result.components,
        total = result.total_count,
        offset = offset,
        limit = limit,
        has_more = result.has_more,
        components = result.components
    })
end

return { handler = handler }
