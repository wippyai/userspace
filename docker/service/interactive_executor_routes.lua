local routes = {}

local ROUTE_TYPE = "docker.interactive_executor"

local function entry_data(entry)
    return type(entry) == "table" and (entry.data or entry) or {}
end

local function validate_route(entry, registry_api)
    local data = entry_data(entry)
    local route_id = type(entry) == "table" and tostring(entry.id or "") or ""
    local image = type(data.image) == "string" and data.image or ""
    local executor_id = type(data.executor) == "string" and data.executor or ""
    if route_id == "" then return nil, "interactive executor route has no id" end
    if image == "" then return nil, route_id .. ": image is required" end
    if executor_id == "" then return nil, route_id .. ": executor is required" end

    local executor, executor_err = registry_api.get(executor_id)
    if executor_err or not executor then
        return nil, route_id .. ": executor not found: " .. executor_id
    end
    if tostring(executor.kind or "") ~= "exec.docker" then
        return nil, route_id .. ": executor must be exec.docker: " .. executor_id
    end
    local executor_data = entry_data(executor)
    if tostring(executor_data.image or "") ~= image then
        return nil, route_id .. ": executor image does not match route image"
    end
    return { route_id = route_id, image = image, executor_id = executor_id }, nil
end

function routes.load(registry_api)
    local entries, find_err = registry_api.find({ ["meta.type"] = ROUTE_TYPE })
    if find_err then return nil, "failed to discover interactive executor routes: " .. tostring(find_err) end
    local result = {}
    for _, entry in ipairs(entries or {}) do
        local route, route_err = validate_route(entry, registry_api)
        if route_err then return nil, route_err end
        if result[route.image] then
            return nil, "duplicate interactive executor route for image: " .. route.image
        end
        result[route.image] = route
    end
    return result, nil
end

-- Re-read both declarations immediately before process creation. This makes a
-- startup snapshot an allowlist, not authority after registry replacement.
function routes.resolve(snapshot, image, registry_api)
    local expected = snapshot and snapshot[image]
    if not expected then return nil, "no interactive executor configured for image: " .. tostring(image) end
    local route_entry, route_err = registry_api.get(expected.route_id)
    if route_err or not route_entry then return nil, "interactive executor route is no longer available" end
    local meta = route_entry.meta or {}
    if meta.type ~= ROUTE_TYPE then return nil, "interactive executor route type changed" end
    local current, current_err = validate_route(route_entry, registry_api)
    if current_err then return nil, current_err end
    if current.image ~= expected.image or current.executor_id ~= expected.executor_id then
        return nil, "interactive executor route changed after worker admission"
    end
    return current, nil
end

return routes
