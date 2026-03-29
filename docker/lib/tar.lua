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

local function build_header(name, size)
    if #name > 99 then
        name = name:sub(1, 99)
    end
    local header = name .. string.rep("\0", 100 - #name)  -- name: 100 bytes
    header = header .. "0000644\0"                         -- mode: 8 bytes
    header = header .. "0000000\0"                         -- uid: 8 bytes
    header = header .. "0000000\0"                         -- gid: 8 bytes
    header = header .. to_octal(size, 12)                  -- size: 12 bytes
    header = header .. to_octal(0, 12)                     -- mtime: 12 bytes
    header = header .. "        "                          -- checksum placeholder: 8 bytes (spaces)
    header = header .. "0"                                 -- typeflag: 1 byte (regular file)
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

return tar
