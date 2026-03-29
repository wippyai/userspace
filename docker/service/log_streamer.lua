local sql = require("sql")
local json = require("json")
local time = require("time")
local env = require("env")
local consts = require("consts")
local containers_repo = require("containers_repo")
local helpers = require("helpers")

local function is_terminal(status)
    return status == consts.status.STOPPED
        or status == consts.status.FAILED
        or status == consts.status.REMOVED
end

local function run(config: {container_id: string, db_id: string?})
    local container_id = config.container_id
    local db_id = config.db_id or env.get(consts.env.DATABASE_RESOURCE)

    local join_ch = process.listen("ws.join", { message = true })
    local leave_ch = process.listen("ws.leave", { message = true })
    local ws_ch = process.listen("ws.message", { message = true })
    local events = process.events()
    local inbox = process.inbox()

    -- wait for WS client to connect
    local client_pid = ""
    while true do
        local result = channel.select({
            join_ch:case_receive(),
            events:case_receive(),
        })
        if result.channel == events then return end
        local data = helpers.extract_ws_data(result.value)
        if type(data) == "table" and data.client_pid then
            client_pid = tostring(data.client_pid)
            break
        elseif type(data) == "string" then
            local decoded = json.decode(data)
            if decoded and decoded.client_pid then
                client_pid = tostring(decoded.client_pid)
                break
            end
        end
    end

    -- subscribe to root for live events before replaying logs
    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if root_pid then
        process.send(root_pid, consts.topic.SUBSCRIBE, json.encode({
            container_id = container_id,
            pid = process.pid(),
        }))
    end

    -- replay existing state from DB
    local last_status = "unknown"
    local db, db_err = sql.get(db_id)
    if db then
        local container = containers_repo.get(db, container_id)
        if container then
            last_status = container.status
        end

        helpers.send_json(client_pid, "ws.message", { event = "status", status = last_status })

        -- replay historical logs from container_logs table
        local logs = containers_repo.get_logs(db, container_id)
        for _, entry in ipairs(logs) do
            helpers.send_json(client_pid, "ws.message", {
                event = "log",
                stream = entry.stream,
                line = entry.line,
            })
        end

        db:release()
    else
        helpers.send_json(client_pid, "ws.message", { event = "status", status = consts.status.FAILED })
    end

    -- drain ticker: after terminal status, wait for stragglers then exit
    local drain_ticker = time.ticker("2s")
    local drain_ch = drain_ticker:channel()
    local terminal = is_terminal(last_status)
    local drain_count = 0

    while true do
        local result = channel.select({
            inbox:case_receive(),
            ws_ch:case_receive(),
            leave_ch:case_receive(),
            events:case_receive(),
            drain_ch:case_receive(),
        })

        if result.channel == events or result.channel == leave_ch then
            break
        end

        if result.channel == inbox then
            local msg = result.value
            local topic = msg:topic()
            local payload = helpers.extract_payload(msg)

            if topic == consts.topic.CONTAINER_LOG and payload then
                helpers.send_json(client_pid, "ws.message", {
                    event = "log",
                    stream = payload.stream,
                    line = payload.line,
                })
                drain_count = 0
            elseif topic == consts.topic.CONTAINER_STATUS and payload then
                last_status = payload.status
                helpers.send_json(client_pid, "ws.message", { event = "status", status = last_status })
                terminal = is_terminal(last_status)
                drain_count = 0
            end
        elseif result.channel == ws_ch then
            local ws_data = helpers.extract_ws_data(result.value)
            if type(ws_data) == "string" then
                local parsed = json.decode(ws_data)
                if parsed and parsed.type == "stdin" and parsed.data and root_pid then
                    process.send(root_pid, consts.topic.STDIN, json.encode({
                        container_id = container_id,
                        data = parsed.data,
                    }))
                end
            end
        else
            if terminal then
                drain_count = drain_count + 1
                if drain_count >= 2 then break end
            end
        end
    end

    drain_ticker:stop()

    if root_pid then
        process.send(root_pid, consts.topic.UNSUBSCRIBE, json.encode({
            container_id = container_id,
            pid = process.pid(),
        }))
    end
end

return { run = run }
