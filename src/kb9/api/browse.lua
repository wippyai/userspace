local http = require("http")
local json = require("json")
local component = require("component")
local api_error = require("api_error")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    if req:method() ~= http.METHOD.GET then
        res:set_status(http.STATUS.METHOD_NOT_ALLOWED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Method not allowed. Use GET."
        })
        return
    end

    -- Get component ID from path parameter
    local component_id = req:param("component_id")
    if not component_id or component_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing required path parameter: component_id"
        })
        return
    end

    -- Parse single-value query parameters
    local node_id = req:query("node_id")
    local parent_id = req:query("parent_id")
    local path = req:query("path")
    local exact_path = req:query("exact_path")
    local search_query = req:query("search_query")
    local include_content = req:query("include_content") == "true"
    local include_metadata = req:query("include_metadata") ~= "false" -- default true
    local with_children_count = req:query("with_children_count") ~= "false" -- default true
    local limit = tonumber(req:query("limit")) or 50
    local offset = tonumber(req:query("offset")) or 0
    local order_by = req:query("order_by") or "path"

    -- Validate order_by
    local valid_order_by = {
        path = true,
        created_at = true,
        updated_at = true,
        level = true,
        node_type = true
    }
    if not valid_order_by[order_by] then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Invalid order_by. Must be one of: path, created_at, updated_at, level, node_type"
        })
        return
    end

    -- Parse array parameters from comma-separated strings

    -- Parse node_ids array
    local node_ids = nil
    local node_ids_str = req:query("node_ids")
    if node_ids_str and node_ids_str ~= "" then
        node_ids = {}
        for node_id_item in node_ids_str:gmatch("[^,]+") do
            local trimmed = node_id_item:match("^%s*(.-)%s*$") -- trim whitespace
            if trimmed and trimmed ~= "" then
                table.insert(node_ids, trimmed)
            end
        end
        if #node_ids == 0 then
            node_ids = nil
        end
    end

    -- Parse levels array from comma-separated string
    local levels = nil
    local levels_str = req:query("levels")
    if levels_str and levels_str ~= "" then
        levels = {}
        for level_str in levels_str:gmatch("[^,]+") do
            local level = tonumber(level_str:match("^%s*(.-)%s*$")) -- trim whitespace
            if level then
                table.insert(levels, level)
            end
        end
        if #levels == 0 then
            levels = nil
        end
    end

    -- Parse node_types array from comma-separated string
    local node_types = nil
    local node_types_str = req:query("node_types")
    if node_types_str and node_types_str ~= "" then
        node_types = {}
        for node_type in node_types_str:gmatch("[^,]+") do
            local trimmed = node_type:match("^%s*(.-)%s*$") -- trim whitespace
            if trimmed and trimmed ~= "" then
                table.insert(node_types, trimmed)
            end
        end
        if #node_types == 0 then
            node_types = nil
        end
    end

    -- Convert empty strings to nil for cleaner handling
    if node_id == "" then node_id = nil end
    if parent_id == "" then parent_id = nil end
    if path == "" then path = nil end
    if exact_path == "" then exact_path = nil end
    if search_query == "" then search_query = nil end

    -- Open KB9 component (access validation happens here)
    local kb9_instance, kb9_err = component.open(component_id, component.ACCESS.READ, "userspace.kb9:kb9_contract")
    if not kb9_instance then
        local status_code = http.STATUS.INTERNAL_ERROR
        if kb9_err and kb9_err:find("not found") then
            status_code = http.STATUS.NOT_FOUND
        elseif kb9_err and (kb9_err:find("access denied") or kb9_err:find("Insufficient access")) then
            status_code = http.STATUS.FORBIDDEN
        end

        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, status_code, "Failed to open KB9 component", kb9_err)
        return
    end

    -- Prepare browse request with all supported parameters
    local browse_request = {
        node_id = node_id,
        node_ids = node_ids,
        parent_id = parent_id,
        path = path,
        exact_path = exact_path,
        levels = levels,
        node_types = node_types,
        search_query = search_query,
        include_content = include_content,
        include_metadata = include_metadata,
        with_children_count = with_children_count,
        limit = limit,
        offset = offset,
        order_by = order_by
    }

    -- Execute browse
    local result, browse_err = kb9_instance:browse(browse_request)
    if browse_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to browse KB9", browse_err)
        return
    end

    -- Check if it's an actual error vs empty results
    if not result.success and result.error then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json(result)
        return
    end

    -- Return success response
    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json(result)
end

return {
    handler = handler
}