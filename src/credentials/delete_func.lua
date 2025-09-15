local ctx = require("ctx")
local credentials_repo = require("credentials_repo")
local component = require("component")

local VALIDATION_ERRORS = {
    MISSING_COMPONENT_ID = "Component ID is required in context"
}

local function handle(request_dto)
    -- Get component_id from context
    local component_id, err = ctx.get("component_id")
    if err or not component_id or component_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    -- Delete credentials (this is called during component cleanup)
    -- No access validation needed here since this is internal cleanup
    local result, repo_err = credentials_repo.delete_credentials(component_id)

    -- Success even if credentials don't exist (already cleaned up)
    if repo_err and repo_err:find("Credentials not found") then
        return { success = true }
    end

    if repo_err then
        return { success = false, error = "Failed to cleanup credentials: " .. repo_err }
    end

    -- Success response
    return { success = true }
end

return { handle = handle }