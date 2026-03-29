local sql = require("sql")
local json = require("json")
local time = require("time")
local env = require("env")
local consts = require("consts")
local images_repo = require("images_repo")
local helpers = require("helpers")

local function is_terminal(status)
    return status == consts.build_status.COMPLETED
        or status == consts.build_status.FAILED
end

local function run(config: {build_id: string, db_id: string?})
    local build_id = config.build_id
    local db_id = config.db_id or env.get(consts.env.DATABASE_RESOURCE)

    local join_ch = process.listen("ws.join", { message = true })
    local leave_ch = process.listen("ws.leave", { message = true })
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

    -- subscribe to root for live build events
    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if root_pid then
        process.send(root_pid, consts.topic.IMAGE_BUILD_SUBSCRIBE, json.encode({
            build_id = build_id,
            pid = process.pid(),
        }))
    end

    -- replay existing build state from DB
    local last_status = "unknown"
    local db, db_err = sql.get(db_id)
    if db then
        local build = images_repo.get_build(db, build_id)
        db:release()

        if build then
            last_status = build.status
            helpers.send_json(client_pid, "ws.message", { event = "status", status = last_status })

            if build.build_log and build.build_log ~= "" then
                local log_text = tostring(build.build_log)
                local pos = 1
                while pos <= #log_text do
                    local nl = log_text:find("\n", pos, true)
                    local line_end = nl and (nl - 1) or #log_text
                    local line = log_text:sub(pos, line_end)
                    if line ~= "" then
                        helpers.send_json(client_pid, "ws.message", { event = "log", line = line })
                    end
                    if not nl then break end
                    pos = nl + 1
                end
            end
        end
    else
        helpers.send_json(client_pid, "ws.message", { event = "status", status = consts.build_status.FAILED })
    end

    local terminal = is_terminal(last_status)
    local drain_count = 0
    local drain_ticker = time.ticker("2s")
    local drain_ch = drain_ticker:channel()

    while true do
        local result = channel.select({
            inbox:case_receive(),
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

            if topic == consts.topic.IMAGE_BUILD_LOG and payload then
                helpers.send_json(client_pid, "ws.message", {
                    event = "log",
                    line = payload.line,
                })
                drain_count = 0
            elseif topic == consts.topic.IMAGE_BUILD_STATUS and payload then
                last_status = payload.status
                helpers.send_json(client_pid, "ws.message", {
                    event = "status",
                    status = last_status,
                    error = payload.error,
                })
                terminal = is_terminal(last_status)
                drain_count = 0
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
        process.send(root_pid, consts.topic.IMAGE_BUILD_UNSUBSCRIBE, json.encode({
            build_id = build_id,
            pid = process.pid(),
        }))
    end
end

return { run = run }
