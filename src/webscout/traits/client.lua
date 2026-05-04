local http_client = require("http_client")
local env = require("env")

local CONFIG = {
    DEFAULT_TIMEOUT = 30,
    MAX_RETRIES = 2,
    RETRY_DELAY = 1
}

local function get_user_agent()
    local user_agent, _ = env.get("userspace.webscout:user_agent")
    return user_agent or
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
end

local function get_default_headers()
    return {
        ["User-Agent"] = get_user_agent(),
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["DNT"] = "1",
        ["Connection"] = "keep-alive",
        ["Upgrade-Insecure-Requests"] = "1",
        ["Sec-Fetch-Dest"] = "document",
        ["Sec-Fetch-Mode"] = "navigate",
        ["Sec-Fetch-Site"] = "none"
    }
end

local function merge_headers(custom_headers)
    ---@type table<string, string>
    local headers = get_default_headers()
    if type(custom_headers) == "table" then
        for k, v in pairs(custom_headers) do
            headers[tostring(k)] = tostring(v)
        end
    end
    return headers
end

local function build_options(options)
    options = options or {}
    local timeout = CONFIG.DEFAULT_TIMEOUT
    if type(options.timeout) == "number" then
        timeout = options.timeout
    end

    local headers: {[string]: string} = merge_headers(options.headers)
    return {
        headers = headers,
        timeout = timeout
    }
end

local function get(url, options)
    local request_options = build_options(options)
    return http_client.get(tostring(url), request_options)
end

local function post(url, options)
    local request_options = build_options(options)
    return http_client.post(tostring(url), request_options)
end

local function request(method, url, options)
    local request_options = build_options(options)
    return http_client.request(tostring(method), tostring(url), request_options)
end

return {
    get = get,
    post = post,
    request = request,
    CONFIG = CONFIG,
    get_user_agent = get_user_agent,
    merge_headers = merge_headers
}
