local json = require("json")
local logger = require("logger")
local pipeline_lib = require("pipeline_lib")
local dispatch = require("dispatch_lib")

local log = logger:named("upload_worker")

local function handler(body)
    local msg, err = json.decode(body)
    if err then
        log:error("failed to decode message", { error = err })
        return nil, "invalid message: " .. err
    end

    local upload_id = msg.upload_id
    if not upload_id or upload_id == "" then
        log:error("message missing upload_id")
        return nil, "missing upload_id"
    end

    local strategy = dispatch.load_strategy()

    local upload, pick_err = dispatch.pick(upload_id, strategy)
    if pick_err then
        log:error("failed to pick an upload to process", {
            strategy = strategy,
            upload_id = upload_id,
            error = pick_err,
        })
        return nil, pick_err
    end

    if not upload then
        return { skipped = true }
    end

    local success, proc_err = pipeline_lib.process_upload(upload)

    if not success then
        log:error("processing failed", {
            upload_id = upload.uuid,
            error = proc_err,
        })
    end

    return { success = success, upload_id = upload.uuid }
end

return { handler = handler }
