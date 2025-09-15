local json = require("json")
local html = require("html")
local client = require("client")

local function clean_content(html_content)
    local policy, err = html.sanitize.strict_policy()
    if err then
        return html_content
    end

    local clean_text = policy:sanitize(html_content)
    return clean_text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function handle(args)
    args = args or {}

    if not args.url or args.url == "" then
        return nil, "URL parameter is required"
    end

    local max_size = args.max_size or 50000
    if max_size > 100000 then max_size = 100000 end
    if max_size < 1000 then max_size = 1000 end

    local options = {
        headers = args.headers
    }

    local response, err = client.get(args.url, options)
    if err then
        return nil, "Failed to fetch page: " .. err
    end

    if response.status_code ~= 200 then
        return nil, "Page returned status " .. response.status_code
    end

    local content_type = response.headers["content-type"] or response.headers["Content-Type"] or ""
    if not content_type:find("text/html") then
        return nil, "Page is not HTML content"
    end

    local content = clean_content(response.body)

    if #content > max_size then
        content = content:sub(1, max_size) .. "... [content truncated]"
    end

    return {
        url = args.url,
        content = content,
        size = #content,
        original_size = #response.body,
        status_code = response.status_code,
        content_type = content_type
    }
end

return { handle = handle }