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

-- create_file(path, content) -> tar bytes for a single file at `path`, with a
-- directory entry for each parent component so the archive can be extracted at "/"
-- regardless of which parents already exist (matches `docker cp` semantics). The
-- leading slash is stripped (tar entries are relative).
function tar.create_file(path: string, content: string): string
    local rel = (tostring(path):gsub("^/+", ""))
    local segs: {string} = {}
    for s in rel:gmatch("[^/]+") do segs[#segs + 1] = s end
    if #segs == 0 then return tar.create({}) end

    local parts: {string} = {}
    local prefix = ""
    for i = 1, #segs - 1 do
        prefix = prefix .. segs[i] .. "/"
        parts[#parts + 1] = build_header(prefix, 0, "5", "0000755")
    end
    local body = content or ""
    parts[#parts + 1] = build_header(rel, #body, "0", "0000644")
    if #body > 0 then
        parts[#parts + 1] = pad_to_512(body)
    end
    parts[#parts + 1] = string.rep("\0", 1024)
    return table.concat(parts)
end

local function parse_octal(s: string): number
    local digits = (s:gsub("[^0-7]", ""))
    if digits == "" then return 0 end
    return tonumber(digits, 8) or 0
end

-- read_first(tar_data) -> (content, name) of the first regular-file entry, or
-- (nil, nil) if the archive holds no file. Walks 512-byte records, skipping
-- directory/other entries. Used to pull a single copied-out file back from a
-- `GET /archive` tar stream.
function tar.read_first(tar_data: string): (string?, string?)
    local data = tostring(tar_data or "")
    local n = #data
    local pos = 1
    while pos + 511 <= n do
        local header = data:sub(pos, pos + 511)
        local name = (header:sub(1, 100):gsub("\0.*$", ""))
        if name == "" then break end -- end-of-archive zero block
        local size = parse_octal(header:sub(125, 136))
        local typeflag = header:sub(157, 157)
        local data_start = pos + 512
        if typeflag == "0" or typeflag == "\0" or typeflag == "" then
            return data:sub(data_start, (data_start + size - 1) :: integer), name
        end
        -- advance past this entry's data (padded to 512)
        local blocks = math.floor((size + 511) / 512)
        pos = data_start + blocks * 512
    end
    return nil, nil
end

return tar
