local http = require("http")
local security = require("security")
local json = require("json")

local upload_lib = require("upload_lib")

local function form_value(values, key): string?
    if type(values) ~= "table" then
        return nil
    end

    local raw = values[key]
    if type(raw) == "string" then
        return raw
    end

    if type(raw) == "table" and type(raw[1]) == "string" then
        return raw[1]
    end

    return nil
end

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

    local filename = file_part:name() or "unknown"
    local mime_type = file_part:header("Content-Type") or "application/octet-stream"
    local file_size = file_part:size() or 0

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
    local stream, err = file_part:stream()
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
    local metadata_str = form_value(form.values, "metadata")
    if metadata_str then
        local decoded, decode_err = json.decode(metadata_str)
        if not decode_err and type(decoded) == "table" then
            metadata = decoded
        end
    end

    -- Extract upload token if provided
    local upload_token = form_value(form.values, "upload_token")
    if upload_token then
        metadata.__upload_token = upload_token
    end

    -- Determine storage type if specified
    local storage_type: string? = form_value(form.values, "storage_type")

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
