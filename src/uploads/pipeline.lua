local time = require("time")
local upload_repo = require("upload_repo")
local upload_lib = require("upload_lib")
local pipeline_lib = require("pipeline_lib")
local logger = require("logger")

-- Create a named logger for this process
local log = logger:named("uploads")

-- Constants for configuration and topics
local CONST = {
    PROCESS_NAME = "upload_pipeline",
    TOPICS = {
        UPLOAD = "process_upload",
        STATUS = "get_upload_status",
        STATUS_RESPONSE = "upload_status_response"
    },
    CONFIG = {
        MAX_QUEUE_SIZE = 10000,
        WORKER_COUNT = 20,
        INITIAL_BATCH_SIZE = 5000
    },
    STATUS = {
        COMPLETED = "completed",
        FAILED = "failed",
        PROCESSING = "processing",
        QUEUED = "queued",
        UPLOADED = "uploaded",
        WAITING = "waiting",
        CANCELED = "canceled"
    }
}

-- Main pipeline function
local function run()
    -- Register with a well-known name
    process.registry.register(CONST.PROCESS_NAME)

    -- Create channels
    local work_channel = channel.new(CONST.CONFIG.MAX_QUEUE_SIZE)    -- Buffered channel for pending work
    local result_channel = channel.new(CONST.CONFIG.MAX_QUEUE_SIZE)  -- Results from workers
    local upload_channel = process.listen(CONST.TOPICS.UPLOAD) -- Channel for upload notifications
    local status_channel = process.listen(CONST.TOPICS.STATUS) -- Channel for status requests
    local events_channel = process.events()             -- Channel for system events

    -- State tracking
    local running = true    -- Control flag for main loop
    local pending_count = 0 -- Number of pending uploads in database
    local waiting_clients = {} -- Map of upload_id -> { client_pids = {}, notified = false }

    -- Worker function - processes uploads from the work channel
    local function worker(worker_id)
        while true do
            -- Wait for work from shared work channel
            local upload, ok = work_channel:receive()
            if not ok then
                -- Channel closed, exit worker
                log:info("Worker shutting down (channel closed)", {
                    worker_id = worker_id
                })
                return
            end

            log:info("Worker processing upload", {
                worker_id = worker_id,
                upload_id = upload.uuid
            })

            -- Process the upload
            local start_time = time.now()
            local success, err = pipeline_lib.process_upload(upload)
            local duration = time.now():sub(start_time):seconds()

            -- Send result back
            result_channel:send({
                upload_id = upload.uuid,
                success = success,
                error = err,
                duration = duration,
                worker_id = worker_id
            })
        end
    end

    -- Handle an upload status request
    local function handle_status_request(message, from_pid)
        if not message or not message.upload_id then
            -- Invalid request
            process.send(from_pid, CONST.TOPICS.STATUS_RESPONSE, {
                success = false,
                error = "Invalid request: missing upload_id",
                request_id = message.request_id
            })
            return
        end

        local upload_id = message.upload_id
        local wait = message.wait or false -- Default to not waiting

        -- Check if upload exists in database
        local upload, err = upload_repo.get(upload_id)
        if err or not upload then
            process.send(from_pid, CONST.TOPICS.STATUS_RESPONSE, {
                success = false,
                error = err or "Upload not found",
                upload_id = upload_id,
                request_id = message.request_id
            })
            return
        end

        -- Check if upload is completed or failed already
        if upload.status == CONST.STATUS.COMPLETED then
            -- Already completed, send response immediately
            process.send(from_pid, CONST.TOPICS.STATUS_RESPONSE, {
                success = true,
                status = CONST.STATUS.COMPLETED,
                upload_id = upload_id,
                request_id = message.request_id
            })
            return
        elseif upload.status == CONST.STATUS.FAILED then
            -- Already failed, send response immediately
            process.send(from_pid, CONST.TOPICS.STATUS_RESPONSE, {
                success = false,
                status = CONST.STATUS.FAILED,
                error = upload.error or "Unknown error",
                upload_id = upload_id,
                request_id = message.request_id
            })
            return
        elseif upload.status == CONST.STATUS.PROCESSING or upload.status == CONST.STATUS.QUEUED or upload.status == CONST.STATUS.UPLOADED then
            -- If client doesn't want to wait, just return current status
            if not wait then
                process.send(from_pid, CONST.TOPICS.STATUS_RESPONSE, {
                    success = true,
                    status = upload.status,
                    upload_id = upload_id,
                    request_id = message.request_id
                })
                return
            end

            -- Upload is in progress or queued, register client for notification
            if not waiting_clients[upload_id] then
                waiting_clients[upload_id] = {
                    client_pids = {},
                    notified = false
                }
            end

            -- Add this client to waiting list
            table.insert(waiting_clients[upload_id].client_pids, from_pid)

            -- Monitor client to detect disconnection
            process.monitor(from_pid)

            -- Send acknowledgment that we're waiting for completion
            process.send(from_pid, CONST.TOPICS.STATUS_RESPONSE, {
                success = true,
                status = CONST.STATUS.WAITING,
                upload_id = upload_id,
                message = "Waiting for upload to complete",
                request_id = message.request_id
            })

            return
        else
            -- Unknown status
            process.send(from_pid, CONST.TOPICS.STATUS_RESPONSE, {
                success = false,
                status = upload.status,
                error = "Unexpected upload status: " .. upload.status,
                upload_id = upload_id,
                request_id = message.request_id
            })
            return
        end
    end

    -- Function to notify waiting clients about upload completion
    local function notify_waiting_clients(upload_id, success, error)
        local waiter_info = waiting_clients[upload_id]
        if not waiter_info or waiter_info.notified then
            return
        end

        -- Send notifications to all waiting clients
        for _, client_pid in ipairs(waiter_info.client_pids) do
            if success then
                process.send(client_pid, CONST.TOPICS.STATUS_RESPONSE, {
                    success = true,
                    status = CONST.STATUS.COMPLETED,
                    upload_id = upload_id
                })
            else
                process.send(client_pid, CONST.TOPICS.STATUS_RESPONSE, {
                    success = false,
                    status = CONST.STATUS.FAILED,
                    error = error or "Unknown error",
                    upload_id = upload_id
                })
            end
        end

        -- Mark as notified and clean up
        waiter_info.notified = true
        waiter_info.client_pids = {} -- Clear client list

        -- Remove after a short delay (give time for messages to be delivered)
        -- In practice, we might want to use a timer here instead
        waiting_clients[upload_id] = nil
    end

    -- Start worker coroutines
    for i = 1, CONST.CONFIG.WORKER_COUNT do
        coroutine.spawn(function()
            worker(i)
        end)
        log:info("Started worker", {
            worker_id = i
        })
    end

    -- Load pending uploads from database into work channel
    local function initialize_work_queue()
        -- Get pending uploads (both uploaded and queued)
        local uploads, err = upload_repo.get_pending_uploads(CONST.CONFIG.INITIAL_BATCH_SIZE)
        if err then
            log:error("Error fetching pending uploads", {
                error = err
            })
            return 0
        end

        if not uploads or #uploads == 0 then
            log:info("No pending uploads found in database")
            return 0
        end

        -- Add uploads to work channel
        local added = 0
        for i, upload in ipairs(uploads) do
            -- Try to add to work channel with non-blocking send
            local result = channel.select({
                work_channel:case_send(upload),
                default = true
            })

            if not result.default then
                -- Successfully added to work channel
                added = added + 1
                log:debug("Added upload to work channel", {
                    upload_id = upload.uuid
                })

                -- If status was queued, update to processing
                if upload.status == CONST.STATUS.QUEUED then
                    upload_repo.update_status(upload.uuid, CONST.STATUS.PROCESSING)
                    pipeline_lib.notify_status_change(upload, CONST.STATUS.PROCESSING)
                end
            else
                -- Work channel is full
                break
            end
        end

        -- Check if there are more pending uploads
        local count_query, err = upload_repo.get_pending_uploads(1, CONST.CONFIG.INITIAL_BATCH_SIZE)
        if not err and count_query and #count_query > 0 then
            -- More uploads pending
            pending_count = #count_query
            log:info("Additional pending uploads detected", {
                count = pending_count
            })
        end

        return added
    end

    -- Try to fetch a pending upload from database
    local function fetch_next_pending()
        if pending_count <= 0 then
            return false
        end

        -- Get one pending upload
        local uploads, err = upload_repo.get_pending_uploads(1)
        if err or not uploads or #uploads == 0 then
            pending_count = 0
            return false
        end

        -- Try to add to work channel
        local result = channel.select({
            work_channel:case_send(uploads[1]),
            default = true
        })

        if not result.default then
            -- Successfully added to work channel
            pending_count = pending_count - 1
            log:debug("Fetched upload from database", {
                upload_id = uploads[1].uuid,
                pending = pending_count
            })

            -- If status was queued, update to processing
            if uploads[1].status == CONST.STATUS.QUEUED then
                upload_repo.update_status(uploads[1].uuid, CONST.STATUS.PROCESSING)
                pipeline_lib.notify_status_change(uploads[1], CONST.STATUS.PROCESSING)
            end

            return true
        end

        return false
    end

    -- Handle a new upload notification
    local function handle_upload_notification(message)
        if not message or not message.upload_id then
            return
        end

        -- Get upload details
        local upload, err = upload_repo.get(message.upload_id)
        if err or not upload then
            log:error("Error getting upload", {
                error = err or "not found",
                upload_id = message.upload_id
            })
            return
        end

        -- Try to add to work channel
        local result = channel.select({
            work_channel:case_send(upload),
            default = true
        })

        if not result.default then
            -- Successfully added to work channel
            log:info("Added upload to work channel from notification", {
                upload_id = upload.uuid
            })
        else
            -- Work channel is full, mark as queued
            upload_repo.update_status(upload.uuid, CONST.STATUS.QUEUED)
            pipeline_lib.notify_status_change(upload, CONST.STATUS.QUEUED)
            pending_count = pending_count + 1
            log:info("Work channel full, marked upload as queued", {
                upload_id = upload.uuid,
                pending = pending_count
            })
        end
    end

    -- Handle clean shutdown
    local function shutdown()
        log:info("Upload pipeline shutting down...")
        running = false

        -- Close work channel (workers will exit when it's empty)
        work_channel:close()

        -- Return any uploads in work channel to uploaded status
        -- Note: we can only do a non-blocking receive in select
        local reset_count = 0
        while true do
            local result = channel.select({
                work_channel:case_receive(),
                default = true
            })

            if result.default then
                -- No more items or channel closed
                break
            end

            local upload = result.value
            upload_repo.update_status(upload.uuid, CONST.STATUS.UPLOADED)
            reset_count = reset_count + 1
            log:debug("Reset upload back to uploaded status", {
                upload_id = upload.uuid
            })
        end

        -- Notify all waiting clients that the pipeline is shutting down
        for upload_id, waiter_info in pairs(waiting_clients) do
            for _, client_pid in ipairs(waiter_info.client_pids) do
                process.send(client_pid, CONST.TOPICS.STATUS_RESPONSE, {
                    success = false,
                    status = CONST.STATUS.CANCELED,
                    error = "Upload pipeline shutting down",
                    upload_id = upload_id
                })
            end
        end

        log:info("Upload pipeline shutdown complete", {
            reset_count = reset_count,
            pending_count = pending_count
        })
        return {
            status = "shutdown",
            reset_count = reset_count,
            pending_count = pending_count
        }
    end

    -- Initialize work queue
    local loaded_count = initialize_work_queue()
    log:info("Initialized pipeline", {
        loaded_count = loaded_count,
        pending_count = pending_count
    })

    -- Main event loop
    log:info("Upload pipeline running", {
        worker_count = CONST.CONFIG.WORKER_COUNT
    })

    while running do
        local result = channel.select({
            upload_channel:case_receive(), -- New upload notification
            result_channel:case_receive(), -- Worker completed an upload
            status_channel:case_receive(), -- Upload status request
            events_channel:case_receive()  -- System events
        })

        if result.channel == upload_channel then
            -- New upload notification
            handle_upload_notification(result.value)
        elseif result.channel == result_channel then
            -- Worker finished processing an upload
            local worker_result = result.value

            log:info("Upload processing finished", {
                upload_id = worker_result.upload_id,
                success = worker_result.success,
                duration = worker_result.duration,
                worker_id = worker_result.worker_id,
                error = worker_result.success and nil or worker_result.error
            })

            -- Update upload status in database
            if worker_result.success then
                upload_repo.update_status(worker_result.upload_id, CONST.STATUS.COMPLETED)
                pipeline_lib.notify_status_change({ uuid = worker_result.upload_id }, CONST.STATUS.COMPLETED)
            else
                upload_repo.update_status(worker_result.upload_id, CONST.STATUS.FAILED, worker_result.error)
                pipeline_lib.notify_status_change({ uuid = worker_result.upload_id }, CONST.STATUS.FAILED, worker_result.error)
            end

            -- Notify any waiting clients
            notify_waiting_clients(worker_result.upload_id, worker_result.success, worker_result.error)

            -- Check if we can fetch a pending upload
            if pending_count > 0 then
                fetch_next_pending()
            end
        elseif result.channel == status_channel then
            -- Upload status request
            handle_status_request(result.value, result.from)
        elseif result.channel == events_channel then
            -- System event
            local event = result.value

            if event.kind == process.event.CANCEL then
                log:info("Received cancel event", {
                    deadline = event.deadline
                })
                return shutdown()
            elseif event.kind == process.event.EXIT then
                -- A monitored process has exited (likely a waiting client)
                local from_pid = event.from

                -- Remove the client from all waiting lists
                for upload_id, waiter_info in pairs(waiting_clients) do
                    local new_clients = {}
                    for _, pid in ipairs(waiter_info.client_pids) do
                        if pid ~= from_pid then
                            table.insert(new_clients, pid)
                        end
                    end
                    waiter_info.client_pids = new_clients

                    -- Clean up empty waiting lists
                    if #new_clients == 0 and not waiter_info.notified then
                        waiting_clients[upload_id] = nil
                    end
                end
            end
        end
    end

    -- Return final pipeline state
    return {
        status = "completed",
        workers = CONST.CONFIG.WORKER_COUNT,
        pending_count = pending_count
    }
end

return { run = run }