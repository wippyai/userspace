local json = require("json")

local helpers = {}

function helpers.extract_payload(msg)
    local raw = msg:payload()
    if type(raw) == "table" and raw[1] then
        local first = raw[1]
        if type(first) == "userdata" then
            raw = first:data()
        else
            raw = first
        end
    elseif type(raw) == "userdata" then
        raw = raw:data()
    end
    if type(raw) == "string" then
        local decoded, err = json.decode(raw)
        if not err then return decoded end
    end
    return raw
end

function helpers.send_json(pid, topic, data)
    process.send(pid, topic, json.encode(data))
end

function helpers.extract_ws_data(msg)
    local payload = msg:payload()
    if not payload then return nil end
    return payload:data()
end

return helpers
