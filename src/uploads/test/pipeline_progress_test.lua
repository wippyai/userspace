local test = require("test")
local sql = require("sql")
local uuid = require("uuid")
local pipeline_lib = require("pipeline_lib")
local upload_repo = require("upload_repo")

local RESUME_TYPE = "app:type.resumable"
local DEFER_TYPE = "app:type.deferable"
local CURSOR = pipeline_lib.CURSOR_KEY
local STATE = pipeline_lib.CURSOR_STATE
local LONG_AGO = "2000-01-01T00:00:00Z"

local function make_upload(type_id, status, metadata)
    local id = uuid.v4()
    local _, err = upload_repo.create(
        id, "user-1", 10, "application/x-resume-test",
        "app:uploads", id .. ".rsm", type_id, metadata or { filename = "x.rsm" },
        status or "uploaded"
    )
    return id, err
end

-- Move updated_at into the past, the way a dead worker leaves a row behind.
local function backdate(id, when)
    local db, err = sql.get("app:db")
    if err then
        return nil, err
    end
    local _, exec_err = sql.builder.update("uploads")
        :set("updated_at", when)
        :where("uuid = ?", id)
        :run_with(db)
        :exec()
    db:release()
    return exec_err == nil, exec_err
end

local function define_tests()
    describe("Pipeline progress cursor", function()
        it("records the next stage as an active cursor after each stage", function()
            local id, create_err = make_upload(RESUME_TYPE)
            test.is_nil(create_err)

            test.eq(pipeline_lib.process_upload(upload_repo.get(id)), true)

            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            test.eq(done.metadata.stage_one_runs, 1)
            test.eq(done.metadata.stage_two_runs, 1)
            test.eq(done.metadata.stage_three_runs, 1)

            -- Stage two was handed the cursor persisted when stage one finished ...
            local seen = test.is_table(done.metadata.stage_two_saw_cursor)
            test.eq(seen.index, 2)
            test.eq(seen.func, "app:stage_two")
            test.eq(seen.state, STATE.ACTIVE)
            test.is_nil(seen.recoveries)

            -- ... and nothing is left behind once the run completed.
            test.is_nil(done.metadata[CURSOR])

            upload_repo.delete(id)
        end)

        it("resumes an interrupted run at the recorded stage", function()
            -- What a dead worker leaves: processing, cursor pointing at stage two.
            local id, create_err = make_upload(RESUME_TYPE, "processing", {
                filename = "x.rsm",
                stage_one_runs = 1,
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.ACTIVE, recoveries = 1 },
            })
            test.is_nil(create_err)

            test.eq(pipeline_lib.process_upload(upload_repo.get(id)), true)

            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            test.eq(done.metadata.stage_one_runs, 1, "stage one must not run again")
            test.eq(done.metadata.stage_two_runs, 1)
            test.eq(done.metadata.stage_three_runs, 1)
            test.eq(done.metadata.stage_two_saw_cursor.recoveries, 1)
            test.is_nil(done.metadata[CURSOR])

            upload_repo.delete(id)
        end)

        it("starts over when the cursor names no stage and carries the recovery count", function()
            -- Recovery writes such a cursor for a run interrupted in its first stage.
            local id, create_err = make_upload(RESUME_TYPE, "processing", {
                filename = "x.rsm",
                [CURSOR] = { state = STATE.ACTIVE, recoveries = 2 },
            })
            test.is_nil(create_err)

            test.eq(pipeline_lib.process_upload(upload_repo.get(id)), true)

            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            test.eq(done.metadata.stage_one_runs, 1)
            test.eq(done.metadata.stage_two_runs, 1)
            test.eq(done.metadata.stage_three_runs, 1)

            local seen = test.is_table(done.metadata.stage_two_saw_cursor)
            test.eq(seen.index, 2)
            test.eq(seen.func, "app:stage_two")
            test.eq(seen.state, STATE.ACTIVE)
            test.eq(seen.recoveries, 2)

            upload_repo.delete(id)
        end)

        it("marks a deferring stage as deferred", function()
            local id, create_err = make_upload(DEFER_TYPE)
            test.is_nil(create_err)

            test.eq(pipeline_lib.process_upload(upload_repo.get(id)), true)

            local parked = upload_repo.get(id)
            test.eq(parked.status, "processing")
            local cursor = test.is_table(parked.metadata[CURSOR])
            test.eq(cursor.index, 2)
            test.eq(cursor.func, "app:stage_defer")
            test.eq(cursor.state, STATE.DEFERRED)
            test.is_true(pipeline_lib.is_deferred(cursor))

            upload_repo.delete(id)
        end)

        it("reads cursors without a state as deferred", function()
            test.is_true(pipeline_lib.is_deferred({ index = 2, func = "app:stage_defer" }))
            test.is_true(pipeline_lib.is_deferred({ state = STATE.DEFERRED }))
            test.is_false(pipeline_lib.is_deferred({ state = STATE.ACTIVE }))
            test.is_false(pipeline_lib.is_deferred({ state = STATE.ACTIVE, recoveries = 1 }))
            test.is_false(pipeline_lib.is_deferred(nil))

            test.eq(pipeline_lib.cursor_of({ metadata = { [CURSOR] = "app:stage_defer" } }).func, "app:stage_defer")
            test.eq(pipeline_lib.cursor_of({ metadata = { [CURSOR] = { index = 3 } } }).index, 3)
            test.is_nil(pipeline_lib.cursor_of({ metadata = {} }))
            test.is_nil(pipeline_lib.cursor_of({}))
            test.is_nil(pipeline_lib.cursor_of(nil))
        end)

        it("heartbeat refreshes the activity timestamp", function()
            local id, create_err = make_upload(RESUME_TYPE, "processing")
            test.is_nil(create_err)
            test.is_true(backdate(id, LONG_AGO))
            test.eq(upload_repo.get(id).updated_at, LONG_AGO)

            local touched, err = pipeline_lib.heartbeat(id)
            test.is_nil(err)
            test.eq(touched.uuid, id)
            test.is_true(touched.updated_at > LONG_AGO)
            test.eq(upload_repo.get(id).updated_at, touched.updated_at)

            local _, missing = pipeline_lib.heartbeat(uuid.v4())
            test.eq(missing, "Upload not found")

            upload_repo.delete(id)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
