local time = require("time")
local logger = require("logger")
local recovery = require("recovery")

local log = logger:named("upload_recovery")

local function sweep(config, publish)
    local ok, result = pcall(recovery.recover_interrupted, {
        cutoff = recovery.cutoff(time.now(), config.stale_after),
        max_attempts = config.max_attempts,
        publish = publish,
    })
    if not ok then
        log:error("recovery sweep raised", { error = tostring(result) })
        return nil
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
