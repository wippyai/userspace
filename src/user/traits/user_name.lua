local security = require("security")

local function handler()
    local actor = security.actor()
    if not actor then
        return "User: Not authenticated"
    end

    local actor_metadata = actor:meta() or {}
    local name = actor_metadata.full_name or "Unknown"

    return "User: " .. name
end

return { handler = handler }