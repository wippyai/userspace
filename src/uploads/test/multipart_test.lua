local test = require("test")
local upload_lib = require("upload_lib")
local upload_repo = require("upload_repo")
local resources = require("uploads_resources")
local uuid = require("uuid")

local function define_tests()
    describe("Multipart uploads", function()
        it("rejects invalid create arguments", function()
            local _, err = upload_lib.create_multipart_upload(nil, "a.pdf", 10)
            test.eq(err, "Invalid user ID")

            local _, err2 = upload_lib.create_multipart_upload("user-1", nil, 10)
            test.eq(err2, "Invalid filename")

            local _, err3 = upload_lib.create_multipart_upload("user-1", "a.pdf", 0)
            test.eq(err3, "Invalid file size")

            local _, err4 = upload_lib.create_multipart_upload("user-1", "a.pdf", -5)
            test.eq(err4, "Invalid file size")
        end)

        it("rejects unsupported file types before touching storage", function()
            -- The test app registers no upload.type entries, so any type
            -- lookup fails — proving the type gate runs first.
            local _, err = upload_lib.create_multipart_upload("user-1", "file.pdf", 1024)
            test.not_nil(err)
            test.eq(err:find("Unsupported file type") ~= nil, true)
        end)

        it("rejects part URL requests for unknown uploads", function()
            local _, err = upload_lib.multipart_part_urls("user-1", uuid.v4(), { 1 })
            test.not_nil(err)
        end)

        it("rejects operations on non-multipart uploads", function()
            local id = uuid.v4()
            local _, create_err = upload_repo.create(
                id, "user-1", 100, "text/plain",
                "app:uploads", id .. ".txt", "app.test:type", { filename = "x.txt" },
                "pending"
            )
            test.is_nil(create_err)

            local _, err = upload_lib.multipart_part_urls("user-1", id, { 1 })
            test.eq(err, "Upload is not a multipart upload")

            local _, err2 = upload_lib.complete_multipart_upload("user-1", id, { { part_number = 1, etag = "e" } })
            test.eq(err2, "Upload is not a multipart upload")

            local _, err3 = upload_lib.abort_multipart_upload("user-1", id)
            test.eq(err3, "Upload is not a multipart upload")

            upload_repo.delete(id)
        end)

        it("enforces ownership on multipart records", function()
            local id = uuid.v4()
            local _, create_err = upload_repo.create(
                id, "owner-user", 100, "text/plain",
                "app:uploads.s3", "owner-user/" .. id .. "/x.txt", "app.test:type",
                { filename = "x.txt", __multipart_upload_id = "mp-123" },
                "pending"
            )
            test.is_nil(create_err)

            local _, err = upload_lib.multipart_part_urls("intruder", id, { 1 })
            test.eq(err, "Access denied: upload belongs to another user")

            local _, err2 = upload_lib.complete_multipart_upload("intruder", id, { { part_number = 1, etag = "e" } })
            test.eq(err2, "Access denied: upload belongs to another user")

            local _, err3 = upload_lib.abort_multipart_upload("intruder", id)
            test.eq(err3, "Access denied: upload belongs to another user")

            upload_repo.delete(id)
        end)

        it("validates part lists on a pending multipart record", function()
            local id = uuid.v4()
            local _, create_err = upload_repo.create(
                id, "user-1", 100, "text/plain",
                "app:uploads.s3", "user-1/" .. id .. "/x.txt", "app.test:type",
                { filename = "x.txt", __multipart_upload_id = "mp-123" },
                "pending"
            )
            test.is_nil(create_err)

            local _, err = upload_lib.multipart_part_urls("user-1", id, {})
            test.eq(err, "At least one part number is required")

            local _, err2 = upload_lib.complete_multipart_upload("user-1", id, {})
            test.eq(err2, "At least one completed part is required")

            upload_repo.delete(id)
        end)

        it("rejects part URLs for non-pending uploads", function()
            local id = uuid.v4()
            local _, create_err = upload_repo.create(
                id, "user-1", 100, "text/plain",
                "app:uploads.s3", "user-1/" .. id .. "/x.txt", "app.test:type",
                { filename = "x.txt", __multipart_upload_id = "mp-123" },
                "uploaded"
            )
            test.is_nil(create_err)

            local _, err = upload_lib.multipart_part_urls("user-1", id, { 1 })
            test.eq(err, "Upload is in invalid state: uploaded")

            -- Completing an already-completed multipart upload is idempotent.
            local upload, err2 = upload_lib.complete_multipart_upload("user-1", id, { { part_number = 1, etag = "e" } })
            test.is_nil(err2)
            test.eq(upload.uuid, id)
            test.eq(upload.status, "uploaded")

            upload_repo.delete(id)
        end)

        it("upload_file rejects unsupported types before writing bytes", function()
            -- No upload.type entries exist in the test app, so the type
            -- gate fails first — no storage access, no orphan bytes.
            local _, err = upload_lib.upload_file("user-1", "content", "file.pdf", 7)
            test.not_nil(err)
            test.eq(err:find("Unsupported file type") ~= nil, true)
        end)

        it("detects storage backends by configured id", function()
            -- The test app wires only filesystem storage; both the default
            -- and explicit fs ids must not be treated as cloud storage.
            test.eq(resources.is_cloud_storage(nil), false)
            test.eq(resources.is_cloud_storage("app:uploads"), false)
            test.eq(resources.is_cloud_storage("app:db"), false)
            -- The configured S3 id is cloud storage by definition, even
            -- when no such registry entry exists in this environment.
            test.eq(resources.is_cloud_storage(resources.get_s3_id()), true)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
