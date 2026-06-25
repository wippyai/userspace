local upload_repo = require("upload_repo")

local M = {}

-- get_info implements wippy.session:file_provider.get_info -- resolve a file_uuid to its
-- upload record (size, mime_type, metadata.filename) so the session can render message
-- attachments without coupling to this uploads module. Returns nil when the upload is
-- absent, which the session treats as an unresolved attachment.
function M.get_info(args)
    local file_uuid = type(args) == "table" and args.file_uuid or nil
    if type(file_uuid) ~= "string" or file_uuid == "" then
        return nil
    end
    local upload = upload_repo.get(file_uuid)
    if type(upload) ~= "table" then
        return nil
    end
    return upload
end

return M
