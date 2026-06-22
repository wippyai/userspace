local http = require("http")
local json = require("json")
local contract = require("contract")
local api_error = require("api_error")

-- Constants
local SCHEDULER_SERVICE_CONTRACT = "userspace.scheduler:scheduler"

local function handler()
    -- Get response and request objects
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Get scheduler service contract
    local scheduler_service, err = contract.get(SCHEDULER_SERVICE_CONTRACT)
    if not scheduler_service then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get scheduler service", err)
        return
    end

    -- Open the service (uses default binding)
    local service, err = scheduler_service:open()
    if not service then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to open scheduler service", err)
        return
    end

    -- Parse query parameters
    local limit = tonumber(req:query("limit")) or 50
    local offset = tonumber(req:query("offset")) or 0
    local status = req:query("status")
    local enabled = req:query("enabled")
    local schedule_type = req:query("schedule_type")
    local task_implementation_id = req:query("task_implementation_id")
    local class = req:query("class") -- Added class filter
    local order_by = req:query("order_by") or "created_at"
    local order_direction = req:query("order_direction") or "DESC"

    -- Validate parameters
    if limit < 1 or limit > 100 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "limit must be between 1 and 100"
        })
        return
    end

    if offset < 0 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "offset must be >= 0"
        })
        return
    end

    -- Validate enabled parameter
    local enabled_bool = nil
    if enabled then
        if enabled == "true" or enabled == "1" then
            enabled_bool = true
        elseif enabled == "false" or enabled == "0" then
            enabled_bool = false
        else
            res:set_status(http.STATUS.BAD_REQUEST)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "enabled must be 'true' or 'false'"
            })
            return
        end
    end

    -- Validate order_by parameter
    local valid_order_fields = { "created_at", "updated_at", "next_run_at" }
    local valid_order_field = false
    for _, field in ipairs(valid_order_fields) do
        if order_by == field then
            valid_order_field = true
            break
        end
    end
    if not valid_order_field then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "order_by must be one of: " .. table.concat(valid_order_fields, ", ")
        })
        return
    end

    -- Validate order_direction parameter
    if order_direction ~= "ASC" and order_direction ~= "DESC" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "order_direction must be 'ASC' or 'DESC'"
        })
        return
    end

    -- Build request DTO
    local request_dto = {
        filters = {
        },
        pagination = {
            limit = limit,
            offset = offset
        },
        ordering = {
            field = order_by,
            direction = order_direction
        }
    }

    -- Add optional filters
    if status and status ~= "" then
        request_dto.filters.status = status
    end

    if enabled_bool ~= nil then
        request_dto.filters.enabled = enabled_bool
    end

    if schedule_type and schedule_type ~= "" then
        request_dto.filters.schedule_type = schedule_type
    end

    if task_implementation_id and task_implementation_id ~= "" then
        request_dto.filters.task_implementation_id = task_implementation_id
    end

    if class and class ~= "" then -- Added class filter to DTO
        request_dto.filters.class = class
    end

    -- Call the service
    local result, err = service:list_schedules(request_dto)
    if not result then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Service call failed", err)
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
        count = #result.schedules,
        total = result.total_count,
        offset = offset,
        limit = limit,
        has_more = result.has_more,
        schedules = result.schedules,
        filters = {
            status = status,
            enabled = enabled,
            schedule_type = schedule_type,
            task_implementation_id = task_implementation_id,
            class = class, -- Added class to response filters
            order_by = order_by,
            order_direction = order_direction
        }
    })
end

return {
    handler = handler
}
