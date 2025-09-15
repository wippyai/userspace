local json = require("json")
local env = require("env")
local client = require("client")
local http_client = require("http_client")

local function handle(args)
    args = args or {}

    if not args.query or args.query == "" then
        return nil, "Query parameter is required and cannot be empty"
    end

    local api_key, err = env.get("userspace.webscout:google_search_api_key")
    if err or not api_key then
        return nil, "Google Search API key not configured"
    end

    local engine_id, err = env.get("userspace.webscout:google_search_engine_id")
    if err or not engine_id then
        return nil, "Google Search Engine ID not configured"
    end

    local num = args.num or 10
    if num > 10 then num = 10 end
    if num < 1 then num = 1 end

    local url = "https://www.googleapis.com/customsearch/v1"
    local query_params = "?key=" .. api_key ..
        "&cx=" .. engine_id ..
        "&q=" .. http_client.encode_uri(args.query) ..
        "&num=" .. tostring(num)

    local response, err = client.get(url .. query_params)
    if err then
        return nil, "Search request failed: " .. err
    end

    if response.status_code ~= 200 then
        return nil, "Search API error: " .. response.status_code
    end

    local data, err = json.decode(response.body)
    if not data then
        return nil, "Failed to parse search results: " .. tostring(err)
    end

    local results = {}
    if data.items then
        for _, item in ipairs(data.items) do
            table.insert(results, {
                title = item.title,
                link = item.link,
                snippet = item.snippet,
                displayLink = item.displayLink
            })
        end
    end

    return {
        query = args.query,
        total_results = data.searchInformation and data.searchInformation.totalResults or 0,
        results = results,
        count = #results
    }
end

return { handle = handle }
