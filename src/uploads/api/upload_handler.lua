local http = require("http")
local security = require("security")
local json = require("json")

local upload_lib = require("upload_lib")

-- Upload file handler
local function handler()
    local req, err = http.request()
    local res = http.response()

    if err then
        -- Handle request creation error
        if res then
            res:set_status(http.STATUS.INTERNAL_ERROR)
            res:write_json({
                success = false,
                error = "Failed to create request context",
                details = err
            })
        end
        return
    end

    if not req or not res then
        return nil, "Failed to get HTTP context"
    end

    -- Set JSON content type for response
    res:set_content_type(http.CONTENT.JSON)

    -- Check for multipart content
    if not req:is_content_type(http.CONTENT.MULTIPART) then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Request must be multipart/form-data"
        })
        return
    end

    -- Get current user from security context
    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Authentication required"
        })
        return
    end

    -- Get user ID from actor
    local user_id = actor:id()
    if not user_id or user_id == "" then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({
            success = false,
            error = "Invalid user ID"
        })
        return
    end

    -- Parse multipart form with size limit
    local max_size = 50 * 1024 * 1024 -- 50MB limit
    local form, err = req:parse_multipart(max_size)
    if err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Failed to parse form data",
            details = err
        })
        return
    end

    -- Check if we have the file field
    if not form.files or not form.files.file or #form.files.file == 0 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "No file uploaded",
            details = "Missing 'file' field in form data"
        })
        return
    end

    -- Get the file from the parsed form
    local file_part = form.files.file[1]

    -- Get file details
    local filename
    if type(file_part.name) == "function" then
        filename = file_part:name()
    elseif type(file_part.filename) == "function" then
        filename = file_part:filename()
    else
        -- Fallback to a property if it exists
        filename = file_part.filename or file_part.name or "unknown"
    end

    -- Get content type
    local mime_type
    if type(file_part.content_type) == "function" then
        mime_type = file_part:content_type() or "application/octet-stream"
    else
        mime_type = file_part.content_type or "application/octet-stream"
    end

    -- Get file size
    local file_size
    if type(file_part.size) == "function" then
        file_size = file_part:size()
    else
        file_size = file_part.size or 0
    end

    -- Validate file
    if file_size <= 0 then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({
            success = false,
            error = "Empty file"
        })
        return
    end

    -- Get file stream
    local stream, err
    if type(file_part.stream) == "function" then
        stream, err = file_part:stream()
    elseif type(file_part.reader) == "function" then
        stream, err = file_part:reader()
    else
        err = "No stream or reader method available on file object"
    end

    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to create file stream",
            details = tostring(err)
        })
        return
    end

    -- Parse metadata if provided
    local metadata = {}
    if form.fields and form.fields.metadata and #form.fields.metadata > 0 then
        local metadata_str = form.fields.metadata[1]
        local success, decoded = pcall(json.decode, metadata_str)
        if success then
            metadata = decoded
        end
    end

    -- Determine storage type if specified
    local storage_type = nil
    if form.fields and form.fields.storage_type and #form.fields.storage_type > 0 then
        storage_type = form.fields.storage_type[1]
    end

    -- Upload the file
    local upload, err = upload_lib.upload_file(
        user_id,
        stream,
        filename,
        file_size,
        mime_type,
        storage_type,
        metadata
    )

    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({
            success = false,
            error = "Failed to upload file",
            details = err
        })
        return
    end

    -- Return success with upload record
    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        uuid = upload.uuid
    })
end

return {
    handler = handler
}