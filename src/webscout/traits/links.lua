local json = require("json")
local text = require("text")
local client = require("client")

local function extract_links(html_content, base_url, absolute_only)
    html_content = tostring(html_content or "")
    local links = {}
    local seen = {}

    local href_regex, _ = text.regexp.compile('<a[^>]+href="([^"]+)"')
    local src_regex, _ = text.regexp.compile('<(?:img|script|link)[^>]+(?:src|href)="([^"]+)"')

    local function process_matches(matches)
        for _, match in ipairs(matches) do
            if #match >= 2 then
                local url = match[2]

                if url:sub(1, 1) == "#" or url:sub(1, 11) == "javascript:" or url:sub(1, 7) == "mailto:" then
                    goto continue
                end

                if url:sub(1, 1) == "/" and base_url then
                    url = base_url .. url
                elseif url:sub(1, 4) ~= "http" and base_url then
                    if url:sub(1, 2) ~= "//" then
                        url = base_url .. "/" .. url
                    else
                        url = "https:" .. url
                    end
                end

                if absolute_only and url:sub(1, 4) ~= "http" then
                    goto continue
                end

                if not seen[url] then
                    seen[url] = true
                    table.insert(links, url)
                end

                ::continue::
            end
        end
    end

    if href_regex then
        local href_matches = href_regex:find_all_string_submatch(html_content)
        process_matches(href_matches)
    end

    if src_regex then
        local src_matches = src_regex:find_all_string_submatch(html_content)
        process_matches(src_matches)
    end

    return links
end

local function get_base_url(url: string): string?
    local domain_regex, _ = text.regexp.compile("^(https?://[^/]+)")
    if domain_regex then
        local matches = domain_regex:find_string_submatch(url)
        if matches and #matches >= 2 then
            return tostring(matches[2])
        end
    end
    return nil
end

local function handle(args)
    args = args or {}

    if not args.url or args.url == "" then
        return nil, "URL parameter is required"
    end

    local absolute_only = args.absolute_only
    if absolute_only == nil then absolute_only = true end

    local response, err = client.get(args.url)
    if err then
        return nil, "Failed to fetch page: " .. err
    end

    if response.status_code ~= 200 then
        return nil, "Page returned status " .. response.status_code
    end

    local base_url = get_base_url(args.url)
    local links = extract_links(response.body, base_url, absolute_only)

    return {
        url = args.url,
        base_url = base_url,
        total_links = #links,
        absolute_only = absolute_only,
        links = links
    }
end

return { handle = handle }
