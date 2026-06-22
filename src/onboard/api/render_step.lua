local http = require("http")
local json = require("json")
local security = require("security")
local templates = require("templates")
local onboard_registry = require("onboard_registry")
local env = require("env")
local api_error = require("api_error")

local function handler()
    local res = http.response()
    local req = http.request()

    if not res or not req then
        return nil, "Failed to get HTTP context"
    end

    -- Security check - ensure user is authenticated
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

    -- Get step name from URL path parameter
    local step_name = req:param("step_name")
    if not step_name or step_name == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Missing step name in path"
        })
        return
    end

    -- Get the step from the registry
    local step, err = onboard_registry.get_by_name(step_name)
    if err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.NOT_FOUND, "Step not found", err)
        return
    end

    -- Check if user can access this step
    if not onboard_registry.can_access(step) then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:set_content_type(http.CONTENT.JSON)
        res:write_json({
            success = false,
            error = "Access denied to step"
        })
        return
    end

    -- Get the template set
    local tmpl, tmpl_err = templates.get(step.template_set)
    if tmpl_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to load template set", tmpl_err)
        return
    end

    -- Render the template with resources context
    local context = {
        resources = step.resources or {},
        env = {
            hostname = env.get("APP_BASE_URL")
        }
    }
    local content, render_err = tmpl:render(step.template_name, context)

    -- Release the template resource
    tmpl:release()

    if render_err then
        res:set_content_type(http.CONTENT.JSON)
        api_error.fail(res, http.STATUS.INTERNAL_ERROR, "Failed to render template", render_err)
        return
    end

    -- Return the rendered HTML
    res:set_content_type("text/html")
    res:set_status(http.STATUS.OK)
    res:write(content)
end

return {
    handler = handler
}
