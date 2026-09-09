local json = require("json")
local time = require("time")
local queue = require("queue")
local env = require("env")
local logger = require("logger")
local upload_repo = require("upload_repo")
local pipeline_lib = require("pipeline_lib")

local log = logger:named("upload_recovery")

local QUEUE_ID = "userspace.uploads:process_queue"

local ENV = table.freeze({
    STALE_AFTER = "userspace.uploads.env:recovery_stale_after",
    INTERVAL = "userspace.uploads.env:recovery_interval",
    MAX_ATTEMPTS = "userspace.uploads.env:recovery_max_attempts",
})

local DEFAULTS = table.freeze({
    stale_after = "30m",
    interval = "5m",
    max_attempts = 3,
})

local BATCH_SIZE = 100

local RECOVERING_STAGE = "Recovering after an interruption"

local recovery = {}

recovery.QUEUE_ID = QUEUE_ID
recovery.DEFAULTS = DEFAULTS
recovery.BATCH_SIZE = BATCH_SIZE
recovery.RECOVERING_STAGE = RECOVERING_STAGE

local function nonblank(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
    if text:match("^%s*$") then
        return nil
    end
    return text
end

local function non_negative_duration(text, name)
    local duration, err = time.parse_duration(text)
    if err then
        return nil, name .. " must be a duration such as 30m or 1h, got '" .. text .. "'"
    end
    if duration:nanoseconds() < 0 then
        return nil, name .. " must not be negative, got '" .. text .. "'"
    end
    return duration
end

function recovery.parse_config(raw)
    raw = raw or {}

    local stale_text = nonblank(raw.stale_after) or DEFAULTS.stale_after
    local stale_after, stale_err = non_negative_duration(stale_text, "recovery_stale_after")
    if not stale_after then
        return nil, stale_err
    end
    if stale_after:nanoseconds() == 0 then
        return nil, "recovery_stale_after must be greater than zero"
    end

    local interval_text = nonblank(raw.interval) or DEFAULTS.interval
    local interval, interval_err = non_negative_duration(interval_text, "recovery_interval")
    if not interval then
        return nil, interval_err
    end
    if interval:nanoseconds() == 0 then
        interval = nil
    end

    local max_attempts = DEFAULTS.max_attempts
    local attempts_text = nonblank(raw.max_attempts)
    if attempts_text then
        local parsed = tonumber(attempts_text)
        if parsed == nil or parsed < 0 or parsed ~= math.floor(parsed) then
            return nil, "recovery_max_attempts must be a whole number of zero or more, got '" .. attempts_text .. "'"
        end
        max_attempts = parsed
    end

    return {
        stale_after = stale_after,
        interval = interval,
        max_attempts = max_attempts,
    }
end

function recovery.load_config()
    local raw = {
        stale_after = env.get(ENV.STALE_AFTER),
        interval = env.get(ENV.INTERVAL),
        max_attempts = env.get(ENV.MAX_ATTEMPTS),
    }

    local config, err = recovery.parse_config(raw)
    if config then
        return config
    end

    log:warn("invalid recovery settings; using defaults", { error = err })
    return recovery.parse_config({})
end

function recovery.cutoff(now, stale_after)
    return now:add(-stale_after:nanoseconds()):format(time.RFC3339)
end

function recovery.queue_publisher()
    return function(upload_id)
        local _, err = queue.publish(QUEUE_ID, json.encode({ upload_id = upload_id }))
        if err then
            return nil, tostring(err)
        end
        return true
    end
end

function recovery.republish_pending(publish, batch_size)
    local summary = { published = 0, errors = 0 }
    local after = nil

    while true do
        local uploads, err = upload_repo.list_pending(after, batch_size or BATCH_SIZE)
        if err then
            log:error("failed to list pending uploads", { error = err })
            summary.errors = summary.errors + 1
            break
        end
        if #uploads == 0 then
            break
        end

        for _, upload in ipairs(uploads) do
            local ok, publish_err = publish(upload.uuid)
            if ok then
                summary.published = summary.published + 1
            else
                summary.errors = summary.errors + 1
                log:error("failed to re-publish pending upload", {
                    upload_id = upload.uuid,
                    error = publish_err,
                })
            end
        end

        after = uploads[#uploads].uuid
    end

    if summary.published > 0 or summary.errors > 0 then
        log:info("re-published pending uploads", summary)
    end

    return summary
end

local function interrupted_message(times)
    local count = times == 1 and "once" or (tostring(times) .. " times")
    return "Processing was interrupted " .. count .. " and did not resume. Retry to process the file again."
end

local function recover_one(upload, opts)
    local cursor = pipeline_lib.cursor_of(upload)
    if pipeline_lib.is_deferred(cursor) then
        return "deferred"
    end

    local interruptions = ((cursor and tonumber(cursor.recoveries)) or 0) + 1
    if interruptions > opts.max_attempts then
        pipeline_lib.fail_upload(upload, interrupted_message(interruptions))
        return "abandoned"
    end

    local next_cursor = {}
    for k, v in pairs(cursor or {}) do
        next_cursor[k] = v
    end
    next_cursor.state = pipeline_lib.CURSOR_STATE.ACTIVE
    next_cursor.recoveries = interruptions

    local metadata = {}
    for k, v in pairs(upload.metadata or {}) do
        metadata[k] = v
    end
    metadata[pipeline_lib.CURSOR_KEY] = next_cursor

    local requeued, requeue_err = upload_repo.requeue_if_stale(upload.uuid, metadata, opts.cutoff)
    if requeue_err then
        log:error("failed to re-queue interrupted upload", { upload_id = upload.uuid, error = requeue_err })
        return "errors"
    end
    if not requeued then
        return "contested"
    end

    upload.metadata = metadata
    pipeline_lib.notify_status_change(upload, pipeline_lib.STATUS.QUEUED, RECOVERING_STAGE)

    local published, publish_err = opts.publish(upload.uuid)
    if not published then
        log:error("re-queued interrupted upload but failed to publish it", {
            upload_id = upload.uuid,
            error = publish_err,
        })
        return "errors"
    end

    log:info("re-queued interrupted upload", {
        upload_id = upload.uuid,
        resume_at = next_cursor.func or "first stage",
        recoveries = interruptions,
    })
    return "requeued"
end

function recovery.recover_interrupted(opts)
    local summary = { examined = 0, requeued = 0, deferred = 0, contested = 0, abandoned = 0, errors = 0 }
    local after = nil

    while true do
        local uploads, err = upload_repo.list_stale_processing(opts.cutoff, after, opts.batch_size or BATCH_SIZE)
        if err then
            log:error("failed to list interrupted uploads", { error = err })
            summary.errors = summary.errors + 1
            break
        end
        if #uploads == 0 then
            break
        end

        for _, upload in ipairs(uploads) do
            summary.examined = summary.examined + 1
            local bucket = recover_one(upload, opts)
            summary[bucket] = summary[bucket] + 1
        end

        after = uploads[#uploads].uuid
    end

    if summary.examined > 0 or summary.errors > 0 then
        log:info("recovery sweep finished", summary)
    end

    return summary
end

return recovery
