local sql = require("sql")
local env = require("env")
local test = require("test")
local images_repo = require("images_repo")

local function get_db()
    local db_id = env.get("userspace.docker.env:database_resource") or "app:db"
    local db, err = sql.get(db_id)
    if err then
        error("failed to get database: " .. tostring(err))
    end
    return db
end

local function cleanup_image(db, id: string)
    db:execute("DELETE FROM image_builds WHERE image_id = ?", { id })
    db:execute("DELETE FROM images WHERE id = ?", { id })
end

local function define_tests()
    describe("Images Persistence", function()

        describe("create and get", function()
            it("creates image and retrieves by id", function()
                local db = get_db()
                local id, err = images_repo.create(db, {
                    name = "test-img",
                    tag = "v1",
                    source = "pulled",
                    status = "available",
                })
                test.is_nil(err, "no error on create")
                test.not_nil(id, "id returned")
                assert(id)

                local img = images_repo.get(db, id)
                test.not_nil(img, "image found")
                test.eq(img.name, "test-img")
                test.eq(img.tag, "v1")
                test.eq(img.source, "pulled")
                test.eq(img.status, "available")

                cleanup_image(db, id)
                db:release()
            end)

            it("returns nil for non-existent id", function()
                local db = get_db()
                local img, err = images_repo.get(db, "does-not-exist-12345")
                test.is_nil(img, "no image found")
                test.is_nil(err, "no error for missing image")
                db:release()
            end)

            it("creates image with default tag", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "no-tag-img",
                    source = "pulled",
                })
                assert(id)

                local img = images_repo.get(db, id)
                test.eq(img.tag, "latest", "default tag is latest")

                cleanup_image(db, id)
                db:release()
            end)

            it("creates image with docker_id and size", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "sized-img",
                    tag = "v1",
                    source = "pulled",
                    docker_id = "sha256:abc123",
                    size = 12345,
                })
                assert(id)

                local img = images_repo.get(db, id)
                test.eq(img.docker_id, "sha256:abc123")
                test.eq(img.size, 12345)

                cleanup_image(db, id)
                db:release()
            end)
        end)

        describe("get_by_name_tag", function()
            it("finds image by name and tag", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "lookup-img",
                    tag = "v2",
                    source = "built",
                })
                assert(id)

                local img = images_repo.get_by_name_tag(db, "lookup-img", "v2")
                test.not_nil(img, "image found by name:tag")
                test.eq(img.id, id)

                cleanup_image(db, id)
                db:release()
            end)

            it("defaults to latest tag when nil", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "default-tag-img",
                    tag = "latest",
                    source = "pulled",
                })
                assert(id)

                local img = images_repo.get_by_name_tag(db, "default-tag-img", nil)
                test.not_nil(img, "found with nil tag (defaults to latest)")
                test.eq(img.id, id)

                cleanup_image(db, id)
                db:release()
            end)

            it("returns nil when name matches but tag differs", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "mismatch-img",
                    tag = "v1",
                    source = "pulled",
                })
                assert(id)

                local img = images_repo.get_by_name_tag(db, "mismatch-img", "v2")
                test.is_nil(img, "no match when tag differs")

                cleanup_image(db, id)
                db:release()
            end)
        end)

        describe("list", function()
            it("returns all images without filter", function()
                local db = get_db()
                local id1 = images_repo.create(db, { name = "list-a", tag = "v1", source = "pulled" })
                local id2 = images_repo.create(db, { name = "list-b", tag = "v1", source = "built", status = "building" })
                assert(id1)
                assert(id2)

                local all = images_repo.list(db)
                test.ok(#all >= 2, "at least two images returned")

                cleanup_image(db, id1)
                cleanup_image(db, id2)
                db:release()
            end)

            it("filters by status", function()
                local db = get_db()
                local id1 = images_repo.create(db, { name = "filter-a", tag = "v1", source = "pulled", status = "available" })
                local id2 = images_repo.create(db, { name = "filter-b", tag = "v1", source = "built", status = "building" })
                assert(id1)
                assert(id2)

                local building = images_repo.list(db, { status = "building" })
                local found = false
                for _, img in ipairs(building) do
                    if img.id == id2 then found = true end
                    test.eq(img.status, "building", "all results have building status")
                end
                test.ok(found, "building image found in filtered list")

                cleanup_image(db, id1)
                cleanup_image(db, id2)
                db:release()
            end)

            it("filters by source", function()
                local db = get_db()
                local id1 = images_repo.create(db, { name = "src-a", tag = "v1", source = "pulled" })
                local id2 = images_repo.create(db, { name = "src-b", tag = "v1", source = "built" })
                assert(id1)
                assert(id2)

                local pulled = images_repo.list(db, { source = "pulled" })
                for _, img in ipairs(pulled) do
                    test.eq(img.source, "pulled", "all results have pulled source")
                end

                cleanup_image(db, id1)
                cleanup_image(db, id2)
                db:release()
            end)
        end)

        describe("update_status", function()
            it("updates status field", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "update-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(id)

                local err = images_repo.update_status(db, id, "available")
                test.is_nil(err, "no error on update")

                local img = images_repo.get(db, id)
                test.eq(img.status, "available")
                test.not_nil(img.updated_at, "updated_at set")

                cleanup_image(db, id)
                db:release()
            end)

            it("updates status with docker_id and size", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "update-fields-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(id)

                images_repo.update_status(db, id, "available", {
                    docker_id = "sha256:updated",
                    size = 99999,
                })

                local img = images_repo.get(db, id)
                test.eq(img.status, "available")
                test.eq(img.docker_id, "sha256:updated")
                test.eq(img.size, 99999)

                cleanup_image(db, id)
                db:release()
            end)

            it("updates status with error", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "error-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(id)

                images_repo.update_status(db, id, "failed", {
                    error = "build timed out",
                })

                local img = images_repo.get(db, id)
                test.eq(img.status, "failed")
                test.eq(img.error, "build timed out")

                cleanup_image(db, id)
                db:release()
            end)
        end)

        describe("delete", function()
            it("removes image record", function()
                local db = get_db()
                local id = images_repo.create(db, {
                    name = "del-img",
                    tag = "v1",
                    source = "pulled",
                })
                assert(id)

                local err = images_repo.delete(db, id)
                test.is_nil(err, "no error on delete")

                local img = images_repo.get(db, id)
                test.is_nil(img, "image gone after delete")
                db:release()
            end)

            it("cascades delete to image_builds", function()
                local db = get_db()
                local img_id = images_repo.create(db, {
                    name = "cascade-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(img_id)

                local build_id = images_repo.create_build(db, {
                    image_id = img_id,
                    dockerfile = "FROM alpine\nRUN echo test",
                })
                test.not_nil(build_id, "build created")
                assert(build_id)

                local build = images_repo.get_build(db, build_id)
                test.not_nil(build, "build exists before delete")

                images_repo.delete(db, img_id)

                local deleted_build = images_repo.get_build(db, build_id)
                test.is_nil(deleted_build, "build removed after image delete")

                db:release()
            end)

            it("returns no error for non-existent id", function()
                local db = get_db()
                local err = images_repo.delete(db, "non-existent-id-12345")
                test.is_nil(err, "delete of non-existent is not an error")
                db:release()
            end)
        end)

        describe("builds", function()
            it("creates and retrieves build", function()
                local db = get_db()
                local img_id = images_repo.create(db, {
                    name = "build-test-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(img_id)

                local build_id, err = images_repo.create_build(db, {
                    image_id = img_id,
                    dockerfile = "FROM alpine\nRUN echo hello",
                })
                test.is_nil(err, "no error on create_build")
                test.not_nil(build_id, "build_id returned")
                assert(build_id)

                local build = images_repo.get_build(db, build_id)
                test.not_nil(build, "build found")
                test.eq(build.image_id, img_id)
                test.eq(build.dockerfile, "FROM alpine\nRUN echo hello")
                test.eq(build.status, "pending")

                cleanup_image(db, img_id)
                db:release()
            end)

            it("claim_build transitions pending to building", function()
                local db = get_db()
                local img_id = images_repo.create(db, {
                    name = "claim-test-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(img_id)

                local build_id = images_repo.create_build(db, {
                    image_id = img_id,
                    dockerfile = "FROM alpine",
                })
                assert(build_id)

                local claimed = images_repo.claim_build(db, build_id)
                test.is_true(claimed, "first claim succeeds")

                local build = images_repo.get_build(db, build_id)
                test.eq(build.status, "building", "status changed to building")
                test.not_nil(build.started_at, "started_at set")

                cleanup_image(db, img_id)
                db:release()
            end)

            it("claim_build rejects already claimed build", function()
                local db = get_db()
                local img_id = images_repo.create(db, {
                    name = "double-claim-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(img_id)

                local build_id = images_repo.create_build(db, {
                    image_id = img_id,
                    dockerfile = "FROM alpine",
                })
                assert(build_id)

                local first = images_repo.claim_build(db, build_id)
                test.is_true(first, "first claim succeeds")

                local second = images_repo.claim_build(db, build_id)
                test.is_false(second, "second claim fails")

                cleanup_image(db, img_id)
                db:release()
            end)

            it("update_build sets status and log", function()
                local db = get_db()
                local img_id = images_repo.create(db, {
                    name = "update-build-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(img_id)

                local build_id = images_repo.create_build(db, {
                    image_id = img_id,
                    dockerfile = "FROM alpine",
                })
                assert(build_id)
                images_repo.claim_build(db, build_id)

                local err = images_repo.update_build(db, build_id, "completed", {
                    build_log = "Step 1/1 : FROM alpine\nSuccessfully built abc123\n",
                })
                test.is_nil(err, "no error on update_build")

                local build = images_repo.get_build(db, build_id)
                test.eq(build.status, "completed")
                test.not_nil(build.completed_at, "completed_at set for terminal status")
                test.ok(tostring(build.build_log):find("Successfully built"), "build log stored")

                cleanup_image(db, img_id)
                db:release()
            end)

            it("update_build records error on failure", function()
                local db = get_db()
                local img_id = images_repo.create(db, {
                    name = "fail-build-img",
                    tag = "v1",
                    source = "built",
                    status = "building",
                })
                assert(img_id)

                local build_id = images_repo.create_build(db, {
                    image_id = img_id,
                    dockerfile = "INVALID",
                })
                assert(build_id)
                images_repo.claim_build(db, build_id)

                images_repo.update_build(db, build_id, "failed", {
                    error = "unknown instruction: INVALID",
                    build_log = "ERROR: unknown instruction\n",
                })

                local build = images_repo.get_build(db, build_id)
                test.eq(build.status, "failed")
                test.eq(build.error, "unknown instruction: INVALID")
                test.not_nil(build.completed_at, "completed_at set for failed status")

                cleanup_image(db, img_id)
                db:release()
            end)

            it("returns nil for non-existent build", function()
                local db = get_db()
                local build = images_repo.get_build(db, "no-such-build-id")
                test.is_nil(build, "non-existent build returns nil")
                db:release()
            end)
        end)
    end)
end

return test.run_cases(define_tests)
