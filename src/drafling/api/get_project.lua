local http = require("http")
local json = require("json")
local security = require("security")
local doc_repo = require("doc_repo")
local api_error = require("api_error")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    local user_id = actor:id()

    local project_id = req:param("id")
    if not project_id or project_id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Project ID is required"
        })
        return
    end

    local project, err = doc_repo.get(project_id, user_id)
    if err then
        if err:match("not found") then
            res:set_status(http.STATUS.NOT_FOUND)
            res:set_content_type(http.CONTENT.JSON)
            res:write_json({
                success = false,
                error = "Project not found"
            })
            return
        end

        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get project", err)
        return
    end

    local include_categories = req:query("include_categories")
    if include_categories == "true" then
        local categories, cat_err = doc_repo.get_categories(project_id)
        if cat_err then
            res:set_content_type(http.CONTENT.JSON)
            api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to get categories", cat_err)
            return
        end
        project.categories = categories
    end

    res:set_status(http.STATUS.OK)
    res:set_content_type(http.CONTENT.JSON)
    res:write_json({
        success = true,
        project = project
    })
end

return {
    handler = handler
}