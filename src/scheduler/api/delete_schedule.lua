local http = require("http")
local json = require("json")
local contract = require("contract")

-- Constants
local SCHEDULER_SERVICE_CONTRACT = "userspace.scheduler:scheduler"

local function handler()
    -- Get response and request objects
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Get task ID from path parameter
    local task_id = req:param("task_id")
    if not task_id or task_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing required path parameter: task_id"
        })
        return
    end

    -- Get scheduler service contract
    local scheduler_service, err = contract.get(SCHEDULER_SERVICE_CONTRACT)
    if not scheduler_service then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to get scheduler service: " .. (err or "unknown error")
        })
        return
    end

    -- Open the service (uses default binding)
    local service, err = scheduler_service:open()
    if not service then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to open scheduler service: " .. (err or "unknown error")
        })
        return
    end

    -- First check if the schedule exists and verify it's a user schedule
    local get_result, get_err = service:get_schedule({ task_id = task_id })
    if not get_result then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Failed to check schedule: " .. (get_err or "unknown error")
        })
        return
    end

    if not get_result.success then
        -- Schedule not found or access denied
        res:set_status(http.STATUS.NOT_FOUND)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Schedule not found"
        })
        return
    end

    -- Check if it's a user schedule (only allow deletion of user schedules)
    if get_result.class ~= "user" then
        res:set_status(http.STATUS.FORBIDDEN)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Can only delete user schedules"
        })
        return
    end

    -- Build delete request DTO
    local request_dto = {
        task_id = task_id
    }

    -- Call the delete service
    local result, err = service:delete_schedule(request_dto)
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
        -- Map common errors to appropriate HTTP status codes
        local status_code = http.STATUS.BAD_REQUEST
        if result.error then
            if result.error:find("not found") or result.error:find("Task not found") then
                status_code = http.STATUS.NOT_FOUND
            elseif result.error:find("access denied") or result.error:find("Insufficient access") then
                status_code = http.STATUS.FORBIDDEN
            end
        end

        res:set_status(status_code)
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
        message = "Schedule deleted successfully",
        task_id = task_id,
        deleted = result.deleted
    })
end

return {
    handler = handler
}
