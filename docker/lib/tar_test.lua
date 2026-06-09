local tar = require("tar")
local test = require("test")

local function define_tests()
    describe("Tar Archive Builder", function()

        it("produces 512-byte aligned archive", function()
            local archive = tar.create({
                { name = "Dockerfile", content = "FROM alpine\nRUN echo ok\n" },
            })
            test.eq(#archive % 512, 0, "archive size must be 512-byte aligned")
            test.ok(#archive >= 512 + 512 + 1024, "archive must have header + data + end blocks")
        end)

        it("contains correct filename in header", function()
            local archive = tar.create({
                { name = "Dockerfile", content = "FROM alpine\n" },
            })
            local name = archive:sub(1, 10)
            test.eq(name, "Dockerfile")
        end)

        it("has ustar magic at correct offset", function()
            local archive = tar.create({
                { name = "test.txt", content = "hello" },
            })
            local magic = archive:sub(258, 263)
            test.eq(magic, "ustar\0")
        end)

        it("has correct file mode", function()
            local archive = tar.create({
                { name = "test.txt", content = "hello" },
            })
            local mode = archive:sub(101, 108)
            test.eq(mode, "0000644\0")
        end)

        it("has valid checksum", function()
            local archive = tar.create({
                { name = "Dockerfile", content = "FROM alpine\n" },
            })

            local stored = archive:sub(149, 154)
            local stored_val = tonumber(stored, 8)
            test.not_nil(stored_val, "checksum must be valid octal")

            local checksum = 0
            for i = 1, 512 do
                if i >= 149 and i <= 156 then
                    checksum = checksum + 32
                else
                    checksum = checksum + string.byte(archive, i)
                end
            end
            test.eq(checksum, stored_val, "computed checksum matches stored")
        end)

        it("pads content to 512 boundary", function()
            local content = "short"
            local archive = tar.create({
                { name = "f.txt", content = content },
            })

            local data_block = archive:sub(513, 1024)
            test.eq(#data_block, 512, "data block must be 512 bytes")
            test.eq(data_block:sub(1, #content), content)
            for i = #content + 1, 512 do
                test.eq(string.byte(data_block, i), 0, "byte " .. i .. " should be null padding")
            end
        end)

        it("ends with 1024 zero bytes", function()
            local archive = tar.create({
                { name = "f.txt", content = "x" },
            })

            local tail = archive:sub(-1024)
            test.eq(#tail, 1024)
            for i = 1, 1024 do
                test.eq(string.byte(tail, i), 0, "end-of-archive byte " .. i .. " must be zero")
            end
        end)

        it("handles multiple files", function()
            local archive = tar.create({
                { name = "a.txt", content = "aaa" },
                { name = "b.txt", content = "bbb" },
            })

            test.eq(#archive % 512, 0)
            test.eq(#archive, 3072, "2 headers + 2 data blocks + end marker")
            test.eq(archive:sub(1, 5), "a.txt")
            test.eq(archive:sub(1025, 1029), "b.txt")
        end)

        it("handles empty content", function()
            local archive = tar.create({
                { name = "empty", content = "" },
            })

            test.eq(#archive, 512 + 1024, "header + end marker only")
        end)

        it("create_file emits a directory entry per parent component", function()
            local archive = tar.create_file("/work/run/model.pt", "weights")
            -- entries are relative (no leading slash) with dir entries first
            test.eq(archive:sub(1, 5), "work/", "first entry is the work/ dir")
            test.eq(string.byte(archive, 157), string.byte("5"), "dir typeflag")
            test.eq(archive:sub(513, 522), "work/run/\0", "second entry is work/run/ dir")
            test.eq(archive:sub(1025, 1042):gsub("\0.*$", ""), "work/run/model.pt", "third entry is the file")
        end)

        it("read_first round-trips create_file content (incl. binary + large)", function()
            for _, payload in ipairs({
                "hello world",
                string.char(0, 1, 2, 255, 254, 10, 13) .. "binary",
                string.rep("checkpoint-bytes-0123456789\n", 20000), -- ~560KB
            }) do
                local archive = tar.create_file("/work/run/data.bin", payload)
                local content, name = tar.read_first(archive)
                test.eq(content, payload)
                test.eq(name, "work/run/data.bin")
            end
        end)

        it("read_first skips directory entries to find the file", function()
            local archive = tar.create_file("a/b/c.txt", "deep")
            local content = tar.read_first(archive)
            test.eq(content, "deep")
        end)

        it("read_first returns nil for an archive with no file", function()
            local content = tar.read_first(string.rep("\0", 1024))
            test.eq(content, nil)
        end)
    end)
end

return test.run_cases(define_tests)
