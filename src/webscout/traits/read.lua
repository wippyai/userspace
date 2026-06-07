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

    local response, err = client.get(args.url)
    if err then
        return nil, "Failed to fetch page: " .. err
    end

    if response.status_code ~= 200 then
        return nil, "Page returned status " .. response.status_code
    end

    local content_type = response.headers["content-type"] or response.headers["Content-Type"] or ""
    local content = response.body or ""

    if content_type:find("text/html") then
        content = clean_content(content)
    elseif not (content_type:find("application/json") or content_type:find("text/")) then
        return nil, "Unsupported content type: " .. content_type
    end

    if #content > max_size then
        content = content:sub(1, max_size) .. "... [content truncated]"
    end

    return content
end

return {
    handle = handle
}
