local time = require("time")
local funcs = require("funcs")
local upload_repo = require("upload_repo")
local upload_type = require("upload_type")
local security = require("security")

-- Upload status constants
local STATUS = {
    UPLOADED = "uploaded",
    QUEUED = "queued",
    PROCESSING = "processing",
    COMPLETED = "completed",
    ERROR = "error"
}

-- Notification topic pattern
local USER_NOTIFICATION_TOPIC = "user.%s"
local UPLOAD_STATUS_TOPIC = "upload:%s"

local pipeline_lib = {}

-- Send notification about upload status change
function pipeline_lib.notify_status_change(upload, status, stage_title, error_msg)
    if not upload or not upload.user_id or not upload.uuid then
        return
    end

    -- Format topics
    local user_topic = string.format(USER_NOTIFICATION_TOPIC, upload.user_id)
    local upload_topic = string.format(UPLOAD_STATUS_TOPIC, upload.uuid)

    -- Prepare notification payload
    local notification = {
        uuid = upload.uuid,
        status = status,
        timestamp = time.now():format_rfc3339()
    }

    -- Add stage title if provided
    if stage_title then
        notification.stage = stage_title
    end

    -- Add error details if available
    if error_msg then
        notification.error = error_msg
    end

    -- Send to user notification topic
    process.send(user_topic, upload_topic, notification)

    print("Sent notification to", user_topic, "about upload", upload.uuid, "status:", status, stage_title and ("stage: " .. stage_title) or "")
end

-- Merge metadata instead of overwriting
function pipeline_lib.merge_metadata(existing_metadata, new_metadata)
    if not existing_metadata then
        return new_metadata
    end

    if not new_metadata then
        return existing_metadata
    end

    local merged = {}

    -- Copy existing metadata
    for k, v in pairs(existing_metadata) do
        merged[k] = v
    end

    -- Merge in new metadata (overwriting existing keys)
    for k, v in pairs(new_metadata) do
        merged[k] = v
    end

    return merged
end

-- Process a single upload using funcs library
function pipeline_lib.process_upload(upload)
    -- Update status to processing
    local _, err = upload_repo.update_status(upload.uuid, STATUS.PROCESSING)
    if err then
        print("Failed to update status for upload", upload.uuid, ":", err)
        return false, "Status update failed: " .. err
    end

    -- Notify about processing status
    pipeline_lib.notify_status_change(upload, STATUS.PROCESSING)

    -- Check if upload has a type_id
    if not upload.type_id or upload.type_id == "" then
        local error_msg = "Upload has no type_id assigned"
        print("Error processing upload", upload.uuid, ":", error_msg)

        -- Update status to error
        local _, update_err = upload_repo.update_status(
            upload.uuid,
            STATUS.ERROR,
            error_msg
        )

        if update_err then
            print("Failed to update error status for upload", upload.uuid, ":", update_err)
        end

        -- Notify about error status
        pipeline_lib.notify_status_change(upload, STATUS.ERROR, nil, error_msg)

        return false, error_msg
    end

    -- Get pipeline stages for this upload type
    local pipeline, err = upload_type.get_pipeline(upload.type_id)
    if err then
        local error_msg = "Failed to get pipeline: " .. err
        print("Error processing upload", upload.uuid, ":", error_msg)

        -- Update status to error
        local _, update_err = upload_repo.update_status(
            upload.uuid,
            STATUS.ERROR,
            error_msg
        )

        if update_err then
            print("Failed to update error status for upload", upload.uuid, ":", update_err)
        end

        -- Notify about error status
        pipeline_lib.notify_status_change(upload, STATUS.ERROR, nil, error_msg)

        return false, error_msg
    end

    local actor = security.new_actor(upload.user_id, { context_id = "upload:" .. upload.uuid })

    -- Create a function executor with context
    local executor = funcs.new():with_context({
        upload_id = upload.uuid,
        user_id = upload.user_id,
        mime_type = upload.mime_type,
        type_id = upload.type_id
    }):with_actor(actor)

    -- Execute each processor in sequence
    for i, stage in ipairs(pipeline) do
        local processor_id = stage.func
        local stage_title = stage.title or ("Stage " .. i)

        print("Running processor", i, processor_id, "for upload", upload.uuid, "stage:", stage_title)

        -- Notify about current stage processing
        pipeline_lib.notify_status_change(upload, STATUS.PROCESSING, stage_title)

        -- Call the processor function
        local result, err = executor:call(processor_id, {
            upload_id = upload.uuid,
            mime_type = upload.mime_type,
            storage_id = upload.storage_id,
            storage_path = upload.storage_path,
            size = upload.size,
            metadata = upload.metadata,
            processor_id = processor_id
        })

        -- Check for errors
        if err or not result then
            local error_msg = tostring(err) or "Processing failed at step " .. i
            print("Error processing upload", upload.uuid, ":", error_msg)

            -- Update status to error
            local _, update_err = upload_repo.update_status(
                upload.uuid,
                STATUS.ERROR,
                error_msg
            )

            if update_err then
                print("Failed to update error status for upload", upload.uuid, ":", update_err)
            end

            -- Notify about error status with stage info
            pipeline_lib.notify_status_change(upload, STATUS.ERROR, stage_title, error_msg)

            return false, error_msg
        end

        -- If the processor returned updated metadata, merge with existing metadata
        if result.metadata then
            -- Get existing metadata
            local existing_metadata = upload.metadata or {}

            -- Merge with new metadata
            local merged_metadata = pipeline_lib.merge_metadata(existing_metadata, result.metadata)

            -- Update the upload record with merged metadata
            local _, metadata_err = upload_repo.update_metadata(upload.uuid, merged_metadata)
            if metadata_err then
                print("Warning: Failed to update metadata for upload", upload.uuid, ":", metadata_err)
            else
                -- Update local copy of metadata
                upload.metadata = merged_metadata
            end
        end
    end

    -- Update status to completed
    local _, update_err = upload_repo.update_status(upload.uuid, STATUS.COMPLETED)
    if update_err then
        print("Failed to update completion status for upload", upload.uuid, ":", update_err)
        return false, "Status update failed: " .. update_err
    end

    -- Notify about completion status
    pipeline_lib.notify_status_change(upload, STATUS.COMPLETED)

    return true
end

-- Export constants
pipeline_lib.STATUS = STATUS

return pipeline_lib