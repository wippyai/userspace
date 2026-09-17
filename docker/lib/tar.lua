local tar = {}

local function to_octal(n, width)
    local s = string.format("%o", n)
    while #s < width - 1 do
        s = "0" .. s
    end
    return s .. "\0"
end

local function pad_to_512(data)
    local remainder = #data % 512
    if remainder == 0 then
        return data
    end
    return data .. string.rep("\0", 512 - remainder)
end

local function build_header(name: string, size: number, typeflag: string?, mode: string?): string
    if #name > 99 then
        name = name:sub(1, 99)
    end
    local header = name .. string.rep("\0", 100 - #name)  -- name: 100 bytes
    header = header .. (mode or "0000644") .. "\0"         -- mode: 8 bytes
    header = header .. "0000000\0"                         -- uid: 8 bytes
    header = header .. "0000000\0"                         -- gid: 8 bytes
    header = header .. to_octal(size, 12)                  -- size: 12 bytes
    header = header .. to_octal(0, 12)                     -- mtime: 12 bytes
    header = header .. "        "                          -- checksum placeholder: 8 bytes (spaces)
    header = header .. (typeflag or "0")                   -- typeflag: 1 byte (0=file, 5=dir)
    header = header .. string.rep("\0", 100)               -- linkname: 100 bytes
    header = header .. "ustar\0"                           -- magic: 6 bytes
    header = header .. "00"                                -- version: 2 bytes
    header = header .. string.rep("\0", 32)                -- uname: 32 bytes
    header = header .. string.rep("\0", 32)                -- gname: 32 bytes
    header = header .. string.rep("\0", 8)                 -- devmajor: 8 bytes
    header = header .. string.rep("\0", 8)                 -- devminor: 8 bytes
    header = header .. string.rep("\0", 155)               -- prefix: 155 bytes
    header = header .. string.rep("\0", 12)                -- pad to 512 bytes

    local checksum = 0
    for i = 1, 512 do
        checksum = checksum + string.byte(header, i)
    end

    local checksum_str = string.format("%06o\0 ", checksum)
    header = header:sub(1, 148) .. checksum_str .. header:sub(157)

    return header
end

function tar.create(files: {{name: string, content: string}}): string
    local parts = {}

    for _, file in ipairs(files) do
        local content = file.content or ""
        table.insert(parts, build_header(file.name, #content))
        if #content > 0 then
            table.insert(parts, pad_to_512(content))
        end
    end

    table.insert(parts, string.rep("\0", 1024))
    return table.concat(parts)
end

local function parse_octal(s: string): number
    local digits = (s:gsub("[^0-7]", ""))
    if digits == "" then return 0 end
    return tonumber(digits, 8) or 0
end

-- read_first(tar_data) -> (content, name, is_dir). Inspects the FIRST archive
-- entry only. A single-file copy yields that file (content, name, false); a
-- directory path yields the directory entry (nil, name, true) so a caller can
-- reject it instead of silently returning a child. (nil, nil, false) for an empty
-- archive. Used to unpack a single file from a `GET /archive` tar stream.
function tar.read_first(tar_data: string): (string?, string?, boolean)
    local data = tostring(tar_data or "")
    if #data < 512 then return nil, nil, false end
    local header = data:sub(1, 512)
    local name = (header:sub(1, 100):gsub("\0.*$", ""))
    if name == "" then return nil, nil, false end
    local typeflag = header:sub(157, 157)
    if typeflag == "5" then return nil, name, true end
    local size = parse_octal(header:sub(125, 136))
    return data:sub(513, (512 + size) :: integer), name, false
end

return tar
