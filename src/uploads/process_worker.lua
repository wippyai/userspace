local json = require("json")
local logger = require("logger")
local pipeline_lib = require("pipeline_lib")
local upload_repo = require("upload_repo")

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

    local upload, err = upload_repo.get(upload_id)
    if err or not upload then
        log:error("upload not found", { upload_id = upload_id, error = err })
        return { skipped = true }
    end

    local success, proc_err = pipeline_lib.process_upload(upload)

    if not success then
        log:error("processing failed", {
            upload_id = upload_id,
            error = proc_err,
        })
    end

    return { success = success }
end

return { handler = handler }
