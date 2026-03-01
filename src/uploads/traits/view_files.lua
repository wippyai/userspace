local security = require("security")
local contract = require("contract")
local ctx = require("ctx")
local fs = require("fs")
local base64 = require("base64")
local json = require("json")

local function is_image_type(content_type)
    return content_type and string.match(content_type, "^image/")
end

local function escape_xml(text)
    if not text then return "" end
    return tostring(text)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub("\"", "&quot;")
        :gsub("'", "&#39;")
end

local function read_raw_file(storage_id: string, storage_path: string)
    local storage = fs.get(storage_id)
    if not storage then
        return nil, "Failed to access storage system: " .. storage_id
    end

    if not storage:exists(storage_path) then
        return nil, "File not found in storage: " .. storage_path
    end

    local file_data = storage:readfile(storage_path)
    if not file_data then
        return nil, "Failed to read file from storage"
    end

    return file_data
end

local function build_xml_response(results)
    local xml_parts = {"<files>"}

    for _, result in ipairs(results) do
        table.insert(xml_parts, string.format("  <file uuid=\"%s\">", escape_xml(result.upload_id)))
        table.insert(xml_parts, string.format("    <filename>%s</filename>", escape_xml(result.filename or "unknown")))
        table.insert(xml_parts, string.format("    <content_type>%s</content_type>", escape_xml(result.content_type or "unknown")))

        if result.total_size then
            table.insert(xml_parts, string.format("    <total_size>%d</total_size>", result.total_size))
        end

        if result.error then
            table.insert(xml_parts, string.format("    <error>%s</error>", escape_xml(result.error)))
        elseif result.content then
            table.insert(xml_parts, string.format("    <content format=\"text\"><![CDATA[%s]]></content>", result.content))
        end

        table.insert(xml_parts, "  </file>")
    end

    table.insert(xml_parts, "</files>")
    return table.concat(xml_parts, "\n")
end

local function build_json_response(results, has_images, has_text)
    local response = {}
    local files = {}
    local images = {}

    local file_names = {}
    for _, result in ipairs(results) do
        if result.filename then
            table.insert(file_names, result.filename)
        end
    end

    if #file_names == 1 then
        if has_images and not has_text then
            response.result = "Image file viewed successfully"
        else
            response.result = "File processed: " .. file_names[1]
        end
    else
        response.result = "Processed " .. #file_names .. " files: " .. table.concat(file_names, ", ")
    end

    for _, result in ipairs(results) do
        if result.error then
            table.insert(files, {
                upload_id = result.upload_id,
                filename = result.filename or "unknown",
                content_type = result.content_type or "unknown",
                error = result.error
            })
        elseif result.is_image and result.content then
            table.insert(files, {
                upload_id = result.upload_id,
                filename = result.filename or "unknown",
                content_type = result.content_type or "unknown",
                total_size = result.total_size,
                note = "Image content attached below"
            })

            table.insert(images, {
                type = "image",
                source = {
                    type = "base64",
                    mime_type = result.content_type or "application/octet-stream",
                    data = result.content
                }
            })
        else
            local file_entry = {
                upload_id = result.upload_id,
                filename = result.filename or "unknown",
                content_type = result.content_type or "unknown",
                total_size = result.total_size
            }

            if result.content then
                file_entry.content = result.content
            end

            table.insert(files, file_entry)
        end
    end

    response.files = files

    if #images > 0 then
        response._images = images
    end

    return json.encode(response)
end

local function handle(args)
    args = args or {}

    local actor = security.actor()
    if not actor then
        return "Error: Authentication required to view files"
    end

    if not args.upload_ids or #args.upload_ids == 0 then
        return "Error: At least one upload ID is required"
    end

    if #args.upload_ids > 10 then
        return "Error: Maximum 10 files can be viewed at once"
    end

    local content_contract, err = contract.get("userspace.contract:content_provider")
    if err then
        return "Error: Failed to get content provider contract: " .. err
    end

    local results = {}
    local has_images = false
    local has_text = false

    for _, upload_id in ipairs(args.upload_ids) do
        local instance, err = content_contract
            :with_context({ upload_id = upload_id })
            :open("userspace.uploads:content_provider")

        if err then
            table.insert(results, {
                upload_id = upload_id,
                error = "Failed to access file: " .. err
            })
        else
            local info: any, err = instance:get_info()
            if err then
                table.insert(results, {
                    upload_id = upload_id,
                    error = "Failed to get file info: " .. err
                })
            else
                local is_image = is_image_type(info.content_type)

                if is_image then
                    has_images = true
                else
                    has_text = true
                end

                if is_image then
                    local raw_content, raw_err = read_raw_file(tostring(info.storage_id), tostring(info.storage_path))
                    if raw_err then
                        table.insert(results, {
                            upload_id = upload_id,
                            filename = info.filename,
                            content_type = info.content_type,
                            total_size = info.size,
                            error = "Failed to read image file: " .. raw_err
                        })
                    else
                        local content_data = base64.encode(raw_content) or raw_content

                        table.insert(results, {
                            upload_id = upload_id,
                            filename = info.filename or "unknown",
                            content_type = info.content_type,
                            total_size = info.size,
                            content = content_data,
                            is_image = true
                        })
                    end
                else
                    local content_result, content_err = instance:get_content()
                    if content_err or not content_result or not content_result.content then
                        local raw_content, raw_err = read_raw_file(tostring(info.storage_id), tostring(info.storage_path))
                        if raw_err then
                            table.insert(results, {
                                upload_id = upload_id,
                                filename = info.filename,
                                content_type = info.content_type,
                                total_size = info.size,
                                error = "Failed to get content: " .. (content_err or raw_err)
                            })
                        else
                            table.insert(results, {
                                upload_id = upload_id,
                                filename = info.filename or "unknown",
                                content_type = info.content_type,
                                total_size = info.size,
                                content = raw_content,
                                is_image = false
                            })
                        end
                    else
                        table.insert(results, {
                            upload_id = upload_id,
                            filename = info.filename or "unknown",
                            content_type = info.content_type,
                            total_size = info.size,
                            content = content_result.content,
                            is_image = false
                        })
                    end
                end
            end
        end
    end

    if has_images then
        return build_json_response(results, has_images, has_text)
    else
        return build_xml_response(results)
    end
end

return { handle = handle }