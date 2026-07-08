local json = require("json")
local queue = require("queue")
local logger = require("logger")
local upload_repo = require("upload_repo")

local log = logger:named("upload_recovery")

local QUEUE_ID = "userspace.uploads:process_queue"
local BATCH_SIZE = 100

local function run()
    local total = 0
    local offset = 0

    while true do
        local uploads, err = upload_repo.get_pending_uploads(BATCH_SIZE, offset)
        if err then
            log:error("failed to fetch pending uploads", { error = err })
            break
        end

        if not uploads or #uploads == 0 then
            break
        end

        for _, upload in ipairs(uploads) do
            local payload = json.encode({ upload_id = upload.uuid })
            local _, pub_err = queue.publish(QUEUE_ID, payload)
            if pub_err then
                log:error("failed to re-enqueue upload", {
                    upload_id = upload.uuid,
                    error = pub_err,
                })
            else
                total = total + 1
            end
        end

        offset = offset + BATCH_SIZE
    end

    if total > 0 then
        log:info("re-enqueued pending uploads", { count = total })
    end

    return { recovered = total }
end

return { run = run }
