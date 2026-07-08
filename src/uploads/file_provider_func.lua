local upload_repo = require("upload_repo")

local M = {}

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
