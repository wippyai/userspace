local reclaim = {}

-- Force-remove any container whose name exactly matches `name`. A container left
-- behind by an ungraceful shutdown keeps its name and host port bindings, which
-- makes the next create conflict (409) or fail to bind. The Docker name filter
-- matches by substring, so the exact "/<name>" entry is selected before removal.
-- Best-effort: returns the number of containers removed and surfaces the first
-- error encountered. The caller decides whether a failure should block create.
function reclaim.reclaim_existing(client, name)
    if not name or name == "" then
        return 0, nil
    end

    local target = "/" .. name
    local existing, list_err = client:list_containers({ name = { name } })
    if list_err then
        return 0, tostring(list_err)
    end

    local removed = 0
    for _, container in ipairs(existing or {}) do
        local matched = false
        for _, candidate in ipairs(container.Names or {}) do
            if candidate == target then
                matched = true
                break
            end
        end
        if matched then
            local _, remove_err = client:remove_container(tostring(container.Id), true)
            if remove_err then
                return removed, tostring(remove_err)
            end
            removed = removed + 1
        end
    end

    return removed, nil
end

return reclaim
