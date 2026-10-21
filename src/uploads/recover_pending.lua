local time = require("time")
local logger = require("logger")
local recovery = require("recovery")
local dispatch = require("dispatch")

local log = logger:named("upload_recovery")

local function sweep(config, publish)
    local cutoff = recovery.cutoff(time.now(), config.stale_after)

    local ok, result = pcall(recovery.recover_interrupted, {
        cutoff = cutoff,
        max_attempts = config.max_attempts,
        publish = publish,
    })
    if not ok then
        log:error("recovery sweep raised", { error = tostring(result) })
        result = nil
    end

    if dispatch.load_strategy() == dispatch.STRATEGY.FAIR then
        local lost_ok, lost_err = pcall(recovery.republish_lost, publish, { cutoff = cutoff })
        if not lost_ok then
            log:error("lost-token sweep raised", { error = tostring(lost_err) })
        end
    end

    return result
end

local function run()
    local config = recovery.load_config()
    local publish = recovery.queue_publisher()

    local pending = recovery.republish_pending(publish)
    local interrupted = sweep(config, publish)

    if not config.interval then
        log:info("periodic recovery disabled; startup pass only")
        return { pending = pending, interrupted = interrupted }
    end

    while true do
        time.sleep(config.interval)
        sweep(config, publish)
    end
end

return { run = run }
