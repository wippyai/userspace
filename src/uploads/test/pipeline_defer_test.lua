local test = require("test")
local pipeline_lib = require("pipeline_lib")
local upload_repo = require("upload_repo")
local uuid = require("uuid")

local DEFER_TYPE = "app:type.deferable"
local FAIL_TYPE = "app:type.defer_then_fail"

local function make_upload(type_id)
    local id = uuid.v4()
    local _, err = upload_repo.create(
        id, "user-1", 10, "application/x-defer-test",
        "app:uploads", id .. ".dfr", type_id, { filename = "x.dfr" },
        "uploaded"
    )
    return id, err
end

local function define_tests()
    describe("Pipeline defer/resume", function()
        it("parks a deferring stage and resumes from it", function()
            local id, create_err = make_upload(DEFER_TYPE)
            test.is_nil(create_err)

            local upload = upload_repo.get(id)
            test.not_nil(upload)

            -- First run parks at the deferring stage: message acked, status
            -- stays processing, stage metadata and the cursor are persisted,
            -- later stages never ran.
            local ok = pipeline_lib.process_upload(upload)
            test.eq(ok, true)

            local parked = upload_repo.get(id)
            test.eq(parked.status, "processing")
            test.eq(parked.metadata.stage_one_runs, 1)
            test.eq(parked.metadata.stage_defer_runs, 1)
            test.eq(parked.metadata.defer_job, "job-123")
            test.is_nil(parked.metadata.stage_three_runs)
            test.not_nil(parked.metadata[pipeline_lib.CURSOR_KEY])
            test.eq(parked.metadata[pipeline_lib.CURSOR_KEY].func, "app:stage_defer")

            -- Re-publish: the worker re-reads the row and processes again.
            -- Stages before the cursor are skipped, the parked stage re-runs.
            local ok2 = pipeline_lib.process_upload(parked)
            test.eq(ok2, true)

            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            test.eq(done.metadata.stage_one_runs, 1)
            test.eq(done.metadata.stage_defer_runs, 2)
            test.eq(done.metadata.stage_three_runs, 1)
            test.is_nil(done.metadata[pipeline_lib.CURSOR_KEY])

            upload_repo.delete(id)
        end)

        it("locates the parked stage by func when positions shift", function()
            local id, create_err = make_upload(DEFER_TYPE)
            test.is_nil(create_err)

            local upload = upload_repo.get(id)
            local ok = pipeline_lib.process_upload(upload)
            test.eq(ok, true)

            -- Simulate a pipeline definition change while parked: the
            -- recorded index no longer matches, but the func still exists.
            local parked = upload_repo.get(id)
            local md = parked.metadata
            md[pipeline_lib.CURSOR_KEY] = { index = 1, func = "app:stage_defer" }
            local _, md_err = upload_repo.update_metadata(id, md)
            test.is_nil(md_err)

            local again = upload_repo.get(id)
            local ok2 = pipeline_lib.process_upload(again)
            test.eq(ok2, true)

            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            -- Resume found the stage by func search: stage one stayed skipped.
            test.eq(done.metadata.stage_one_runs, 1)
            test.eq(done.metadata.stage_three_runs, 1)

            upload_repo.delete(id)
        end)

        it("clears the cursor on error and re-drives from the first stage", function()
            local id, create_err = make_upload(FAIL_TYPE)
            test.is_nil(create_err)

            local upload = upload_repo.get(id)
            local ok = pipeline_lib.process_upload(upload)
            test.eq(ok, true)

            local parked = upload_repo.get(id)
            test.eq(parked.status, "processing")

            -- Resume: the deferring stage succeeds, the next stage raises.
            local ok2, err2 = pipeline_lib.process_upload(parked)
            test.eq(ok2, false)
            test.not_nil(err2)

            local failed = upload_repo.get(id)
            test.eq(failed.status, "error")
            test.is_nil(failed.metadata[pipeline_lib.CURSOR_KEY])
            test.eq(failed.metadata.stage_one_runs, 1)

            -- With the cursor gone, a manual re-drive of the errored upload
            -- runs the full pipeline again.
            local ok3 = pipeline_lib.process_upload(failed)
            test.eq(ok3, false)

            local redriven = upload_repo.get(id)
            test.eq(redriven.status, "error")
            test.eq(redriven.metadata.stage_one_runs, 2)
            test.eq(redriven.metadata.stage_defer_runs, 3)

            upload_repo.delete(id)
        end)

        it("fails explicitly when the recorded stage vanished", function()
            local id, create_err = make_upload(DEFER_TYPE)
            test.is_nil(create_err)

            local upload = upload_repo.get(id)
            local md = upload.metadata or {}
            md[pipeline_lib.CURSOR_KEY] = { index = 9, func = "app:stage_gone" }
            local _, md_err = upload_repo.update_metadata(id, md)
            test.is_nil(md_err)

            local fresh = upload_repo.get(id)
            local ok, err = pipeline_lib.process_upload(fresh)
            test.eq(ok, false)
            test.not_nil(err)
            test.eq(err:find("Cannot resume deferred upload", 1, true) ~= nil, true)

            local failed = upload_repo.get(id)
            test.eq(failed.status, "error")
            test.is_nil(failed.metadata[pipeline_lib.CURSOR_KEY])
            -- No stage ever ran.
            test.is_nil(failed.metadata.stage_one_runs)

            upload_repo.delete(id)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
