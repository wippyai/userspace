local http_client = require("http_client")
local env = require("env")

local CONFIG = {
    DEFAULT_TIMEOUT = 30,
    MAX_RETRIES = 2,
    RETRY_DELAY = 1
}

local function get_user_agent(): string
    local user_agent, _ = env.get("userspace.webscout:user_agent")
    return user_agent or
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
end

local function get_default_headers(): {[string]: string}
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

local function merge_headers(custom_headers: {[string]: string}?): {[string]: string}
    local headers = get_default_headers()
    if custom_headers then
        for k, v in pairs(custom_headers) do
            headers[k] = v
        end
    end
    return headers
end

local function get(url: string, options: http_client.RequestOptions?): (http_client.Response, any)
    options = options or {}
    options.headers = merge_headers(options.headers)
    options.timeout = options.timeout or CONFIG.DEFAULT_TIMEOUT
    return http_client.get(url, options)
end

local function post(url: string, options: http_client.RequestOptions?): (http_client.Response, any)
    options = options or {}
    options.headers = merge_headers(options.headers)
    options.timeout = options.timeout or CONFIG.DEFAULT_TIMEOUT
    return http_client.post(url, options)
end

local function request(method: string, url: string, options: http_client.RequestOptions?): (http_client.Response, any)
    options = options or {}
    options.headers = merge_headers(options.headers)
    options.timeout = options.timeout or CONFIG.DEFAULT_TIMEOUT
    return http_client.request(method, url, options)
end

return {
    get = get,
    post = post,
    request = request,
    CONFIG = CONFIG,
    get_user_agent = get_user_agent,
    merge_headers = merge_headers
}
