local consts = require("consts")

local scope = {}

---Resolve the named security scope a user runs under, given their security
---group memberships. The admin group wins outright and stops the search;
---otherwise the last group in the list wins. Nil or empty groups resolve to
---the configured default group.
---@param groups string[]|nil User security group ids
---@return string scope_id Named security scope id
function scope.resolve(groups)
    local config = consts.get_config()
    local scope_id = config.default_group_id

    if groups then
        for _, group_id in ipairs(groups) do
            if group_id == config.admin_group_id then
                return config.admin_group_id
            end
            scope_id = group_id
        end
    end

    return scope_id
end

return scope
