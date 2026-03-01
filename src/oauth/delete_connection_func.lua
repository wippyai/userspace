local ctx = require("ctx")
local oauth_repo = require("oauth_repo")
local component = require("component")
local contract = require("contract")

-- Constants
local SCHEDULER_CONTRACT = "userspace.scheduler:scheduler"

local function handle(request_dto)
    -- Get component ID from context
    local component_id, err = ctx.get("component_id")
    if err then
        return {
            success = false,
            error = "No component context: " .. err
        }
    end

    -- Validate access to component
    local access_level, access_err = component.validate_access(component_id :: string, component.ACCESS.DELETE)
    if not access_level then
        return {
            success = false,
            error = "Access denied: " .. (access_err or "insufficient permissions")
        }
    end

    -- Get connection metadata to find schedule_id before deletion
    local connection_metadata, metadata_err = oauth_repo.get_connection_metadata(component_id)
    local schedule_id = nil
    if not metadata_err and connection_metadata and connection_metadata.schedule_id then
        schedule_id = connection_metadata.schedule_id
    end

    -- Delete the token refresh schedule if it exists
    if schedule_id then
        local scheduler_contract, scheduler_err = contract.get(SCHEDULER_CONTRACT)
        if not scheduler_err then
            local scheduler_instance, open_err = scheduler_contract:open()
            if not open_err then
                scheduler_instance:delete_schedule({
                    task_id = schedule_id
                })
            end
        end
    end

    -- Delete the OAuth connection and all its data
    local delete_result, delete_err = oauth_repo.delete_connection(component_id)
    if delete_err then
        return {
            success = false,
            error = "Failed to delete OAuth connection: " .. delete_err
        }
    end

    -- Return success according to deletable contract
    return {
        success = true
    }
end

return { handle = handle }
