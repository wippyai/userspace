local env = require("env")
local time = require("time")
local logger = require("logger")
local upload_repo = require("upload_repo")

local log = logger:named("upload_dispatch")

local STRATEGY = table.freeze({
    FIFO = "fifo",
    FAIR = "fair",
})

local ENV_STRATEGY = "userspace.uploads.env:queue_strategy"

local STRATEGY_CACHE_NS = 5 * 1000000000
local LOST_RACE_ATTEMPTS = 200
local LOST_RACE_PAUSE_MS = { 10, 60 }
local ERROR_ATTEMPTS = 5
local ERROR_PAUSE_MS = { 500, 1500 }

local dispatch = {}

dispatch.STRATEGY = STRATEGY
dispatch.LOST_RACE_ATTEMPTS = LOST_RACE_ATTEMPTS
dispatch.ERROR_ATTEMPTS = ERROR_ATTEMPTS

local strategy_cache = { value = nil, expires = 0 }

function dispatch.parse_strategy(raw)
    if raw == nil then
        return STRATEGY.FIFO
    end

    local text = tostring(raw):lower():match("^%s*(.-)%s*$")
    if text == "" then
        return STRATEGY.FIFO
    end

    if text == STRATEGY.FIFO or text == STRATEGY.FAIR then
        return text
    end

    return nil, "queue_strategy must be fifo or fair, got '" .. tostring(raw) .. "'"
end

local function not_found(err)
    return tostring(err):find("not found", 1, true) ~= nil
end

function dispatch.load_strategy()
    local now = time.now():unix_nano()
    if strategy_cache.value and now < strategy_cache.expires then
        return strategy_cache.value
    end

    local raw, env_err = env.get(ENV_STRATEGY)
    local strategy, parse_err = dispatch.parse_strategy(raw)
    if env_err and not not_found(env_err) then
        log:warn("could not read queue strategy; using fifo", { error = tostring(env_err) })
        strategy = STRATEGY.FIFO
    elseif not strategy then
        log:warn("invalid queue strategy; using fifo", { value = tostring(raw), error = parse_err })
        strategy = STRATEGY.FIFO
    end

    strategy_cache.value = strategy
    strategy_cache.expires = now + STRATEGY_CACHE_NS
    return strategy
end

function dispatch.turn_now()
    return math.floor(time.now():unix_nano() / 1000)
end

local function pause_for(range)
    time.sleep(tostring(math.random(range[1], range[2])) .. "ms")
end

local function attempt(claim)
    local user_id, turn_err = upload_repo.next_turn()
    if turn_err then
        return nil, "error", turn_err
    end
    if not user_id then
        return nil, "empty"
    end

    local upload, oldest_err = upload_repo.oldest_pending(user_id)
    if oldest_err then
        return nil, "error", oldest_err
    end
    if not upload then
        return nil, "lost"
    end

    local taken, claim_err = claim(upload.uuid)
    if claim_err then
        return nil, "error", claim_err
    end
    if not taken then
        return nil, "lost"
    end

    return upload, "claimed"
end

function dispatch.claim_next(opts)
    opts = opts or {}
    local attempts = opts.attempts or LOST_RACE_ATTEMPTS
    local error_attempts = opts.error_attempts or ERROR_ATTEMPTS
    local claim = opts.claim or upload_repo.claim
    local record_turn = opts.record_turn or upload_repo.record_turn
    local turn = opts.turn or dispatch.turn_now
    local pause = opts.pause or pause_for

    local lost = 0
    local failures = 0

    while true do
        local upload, outcome, err = attempt(claim)

        if outcome == "claimed" then
            local _, record_err = record_turn(upload.user_id, turn())
            if record_err then
                log:warn("claimed an upload but could not record the turn", {
                    user_id = upload.user_id,
                    upload_id = upload.uuid,
                    error = record_err,
                })
            end
            upload.status = "processing"
            return upload
        end

        if outcome == "empty" then
            return nil
        end

        if outcome == "lost" then
            lost = lost + 1
            pause(LOST_RACE_PAUSE_MS)
            if lost >= attempts then
                return nil, "no upload could be claimed in " .. attempts .. " attempts"
            end
        else
            failures = failures + 1
            log:warn("claim attempt failed", { attempt = failures, error = tostring(err) })
            pause(ERROR_PAUSE_MS)
            if failures >= error_attempts then
                return nil, err
            end
        end
    end
end

function dispatch.pick(upload_id, strategy)
    if strategy == STRATEGY.FAIR then
        return dispatch.claim_next()
    end

    local upload, err = upload_repo.get(upload_id)
    if err or not upload then
        log:error("upload not found", { upload_id = upload_id, error = err })
        return nil
    end

    return upload
end

return dispatch
