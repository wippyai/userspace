local test = require("test")
local sql = require("sql")
local time = require("time")
local uuid = require("uuid")
local recovery = require("recovery")
local pipeline_lib = require("pipeline_lib")
local upload_repo = require("upload_repo")

local RESUME_TYPE = "app:type.resumable"
local CURSOR = pipeline_lib.CURSOR_KEY
local STATE = pipeline_lib.CURSOR_STATE
local LONG_AGO = "2000-01-01T00:00:00Z"

local function make_upload(status, metadata)
    local id = uuid.v4()
    local _, err = upload_repo.create(
        id, "user-1", 10, "application/x-resume-test",
        "app:uploads", id .. ".rsm", RESUME_TYPE, metadata or { filename = "x.rsm" },
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

-- A publisher that only remembers what it was asked to publish.
local function recorder()
    local published = {}
    return published, function(upload_id)
        published[#published + 1] = upload_id
        return true
    end
end

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

local function cutoff_now()
    -- Rows written by this run are fresh; rows backdated to LONG_AGO are stale.
    return recovery.cutoff(time.now(), time.parse_duration("1m"))
end

local function cleanup(...)
    for _, id in ipairs({ ... }) do
        upload_repo.delete(id)
    end
end

local function define_tests()
    describe("Recovery repository queries", function()
        it("lists pending uploads by uuid and pages by the last uuid seen", function()
            local uploaded = make_upload("uploaded")
            local queued = make_upload("queued")
            local processing = make_upload("processing")
            local completed = make_upload("completed")

            local seen = {}
            local after = nil
            while true do
                local rows, err = upload_repo.list_pending(after, 1)
                test.is_nil(err)
                if #rows == 0 then
                    break
                end
                test.eq(#rows, 1)
                if after then
                    test.is_true(rows[1].uuid > after, "pages must advance by uuid")
                end
                seen[rows[1].uuid] = rows[1].status
                after = rows[1].uuid
            end

            test.eq(seen[uploaded], "uploaded")
            test.eq(seen[queued], "queued")
            test.is_nil(seen[processing])
            test.is_nil(seen[completed])

            cleanup(uploaded, queued, processing, completed)
        end)

        it("lists processing uploads untouched since the cutoff", function()
            local stale = make_upload("processing")
            test.is_true(backdate(stale, LONG_AGO))
            local fresh = make_upload("processing")
            local other_status = make_upload("uploaded")
            test.is_true(backdate(other_status, LONG_AGO))

            local ids = {}
            local after = nil
            while true do
                local rows, err = upload_repo.list_stale_processing(cutoff_now(), after, 1)
                test.is_nil(err)
                if #rows == 0 then
                    break
                end
                if after then
                    test.is_true(rows[1].uuid > after, "pages must advance by uuid")
                end
                test.eq(rows[1].status, "processing")
                test.is_table(rows[1].metadata)
                ids[#ids + 1] = rows[1].uuid
                after = rows[1].uuid
            end

            test.is_true(contains(ids, stale))
            test.is_false(contains(ids, fresh))
            test.is_false(contains(ids, other_status))

            local _, err = upload_repo.list_stale_processing(nil)
            test.eq(err, "Cutoff is required")

            cleanup(stale, fresh, other_status)
        end)

        it("re-queues a stale row once and never a live one", function()
            local stale = make_upload("processing", { filename = "x.rsm", keep = "me" })
            test.is_true(backdate(stale, LONG_AGO))

            local metadata = { filename = "x.rsm", keep = "me", [CURSOR] = { state = STATE.ACTIVE, recoveries = 1 } }
            local won, err = upload_repo.requeue_if_stale(stale, metadata, cutoff_now())
            test.is_nil(err)
            test.eq(won, true)

            local row = upload_repo.get(stale)
            test.eq(row.status, "queued")
            test.eq(row.metadata.keep, "me")
            test.eq(row.metadata[CURSOR].recoveries, 1)
            test.is_true(row.updated_at > LONG_AGO)

            -- No longer processing: the compare-and-set finds nothing to take.
            test.eq(upload_repo.requeue_if_stale(stale, row.metadata, cutoff_now()), false)

            -- A worker's row, touched just now, is not stale.
            local live = make_upload("processing")
            test.eq(upload_repo.requeue_if_stale(live, { filename = "x.rsm" }, cutoff_now()), false)
            test.eq(upload_repo.get(live).status, "processing")

            local _, no_id = upload_repo.requeue_if_stale(nil, {}, LONG_AGO)
            test.eq(no_id, "Upload ID is required")
            local _, no_metadata = upload_repo.requeue_if_stale(stale, "nope", LONG_AGO)
            test.eq(no_metadata, "Metadata is required")
            local _, no_cutoff = upload_repo.requeue_if_stale(stale, {}, nil)
            test.eq(no_cutoff, "Cutoff is required")

            cleanup(stale, live)
        end)
    end)

    describe("Recovery settings", function()
        it("falls back to defaults and validates what is set", function()
            local defaults, err = recovery.parse_config({})
            test.is_nil(err)
            test.eq(defaults.stale_after:minutes(), 30)
            test.eq(defaults.interval:minutes(), 5)
            test.eq(defaults.max_attempts, 3)

            local custom = recovery.parse_config({ stale_after = "1h", interval = "0", max_attempts = "5" })
            test.eq(custom.stale_after:hours(), 1)
            test.is_nil(custom.interval, "a zero interval disables the periodic sweep")
            test.eq(custom.max_attempts, 5)

            local blank = recovery.parse_config({ stale_after = "  ", interval = "", max_attempts = " " })
            test.eq(blank.stale_after:minutes(), 30)
            test.eq(blank.interval:minutes(), 5)
            test.eq(blank.max_attempts, 3)

            local none = recovery.parse_config({ max_attempts = "0" })
            test.eq(none.max_attempts, 0)

            local _, bad_duration = recovery.parse_config({ stale_after = "soon" })
            test.contains(bad_duration, "recovery_stale_after")
            local _, zero = recovery.parse_config({ stale_after = "0" })
            test.contains(zero, "greater than zero")
            local _, negative = recovery.parse_config({ interval = "-5m" })
            test.contains(negative, "recovery_interval")
            local _, fraction = recovery.parse_config({ max_attempts = "1.5" })
            test.contains(fraction, "recovery_max_attempts")
            local _, negative_attempts = recovery.parse_config({ max_attempts = "-1" })
            test.contains(negative_attempts, "recovery_max_attempts")
            local _, words = recovery.parse_config({ max_attempts = "three" })
            test.contains(words, "recovery_max_attempts")
        end)

        it("formats the cutoff the way rows are stamped", function()
            local now = time.now()
            local cutoff = recovery.cutoff(now, time.parse_duration("30m"))
            test.eq(cutoff, now:add(-30 * 60 * 1000000000):format(time.RFC3339))
            test.is_true(cutoff < now:format(time.RFC3339))
        end)
    end)

    describe("Recovery of interrupted processing", function()
        it("re-publishes uploads that were never picked up", function()
            local uploaded = make_upload("uploaded")
            local queued = make_upload("queued")
            local processing = make_upload("processing")

            local published, publish = recorder()
            local summary = recovery.republish_pending(publish, 1)
            test.is_true(contains(published, uploaded))
            test.is_true(contains(published, queued))
            test.is_false(contains(published, processing))
            test.gte(summary.published, 2)
            test.eq(summary.errors, 0)

            -- A publisher that fails is counted, not fatal.
            local failing = recovery.republish_pending(function()
                return nil, "queue down"
            end)
            test.eq(failing.published, 0)
            test.gte(failing.errors, 2)

            cleanup(uploaded, queued, processing)
        end)

        it("hands an interrupted run back to the queue at its recorded stage", function()
            local id = make_upload("processing", {
                filename = "x.rsm",
                stage_one_runs = 1,
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.ACTIVE },
            })
            test.is_true(backdate(id, LONG_AGO))

            local published, publish = recorder()
            local summary = recovery.recover_interrupted({ cutoff = cutoff_now(), max_attempts = 3, publish = publish })
            test.gte(summary.examined, 1)
            test.gte(summary.requeued, 1)
            test.is_true(contains(published, id))

            local queued = upload_repo.get(id)
            test.eq(queued.status, "queued")
            test.eq(queued.metadata.stage_one_runs, 1)
            local cursor = test.is_table(queued.metadata[CURSOR])
            test.eq(cursor.index, 2)
            test.eq(cursor.func, "app:stage_two")
            test.eq(cursor.state, STATE.ACTIVE)
            test.eq(cursor.recoveries, 1)

            -- The worker that picks the message up resumes at stage two.
            test.eq(pipeline_lib.process_upload(queued), true)
            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            test.eq(done.metadata.stage_one_runs, 1, "stage one must not run again")
            test.eq(done.metadata.stage_two_runs, 1)
            test.eq(done.metadata.stage_three_runs, 1)
            test.eq(done.metadata.stage_two_saw_cursor.recoveries, 1)
            test.is_nil(done.metadata[CURSOR])

            cleanup(id)
        end)

        it("starts a run interrupted in its first stage from the beginning", function()
            local id = make_upload("processing")
            test.is_true(backdate(id, LONG_AGO))

            local published, publish = recorder()
            recovery.recover_interrupted({ cutoff = cutoff_now(), max_attempts = 3, publish = publish })
            test.is_true(contains(published, id))

            local queued = upload_repo.get(id)
            test.eq(queued.status, "queued")
            local cursor = test.is_table(queued.metadata[CURSOR])
            test.is_nil(cursor.func)
            test.eq(cursor.state, STATE.ACTIVE)
            test.eq(cursor.recoveries, 1)

            test.eq(pipeline_lib.process_upload(queued), true)
            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            test.eq(done.metadata.stage_one_runs, 1)
            test.eq(done.metadata.stage_two_runs, 1)
            test.eq(done.metadata.stage_three_runs, 1)
            test.eq(done.metadata.stage_two_saw_cursor.recoveries, 1)

            cleanup(id)
        end)

        it("leaves fresh runs and deferred runs alone", function()
            local fresh = make_upload("processing")
            local deferred = make_upload("processing", {
                filename = "x.rsm",
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.DEFERRED },
            })
            test.is_true(backdate(deferred, LONG_AGO))
            local legacy = make_upload("processing", {
                filename = "x.rsm",
                [CURSOR] = { index = 2, func = "app:stage_two" },
            })
            test.is_true(backdate(legacy, LONG_AGO))

            local published, publish = recorder()
            local summary = recovery.recover_interrupted({ cutoff = cutoff_now(), max_attempts = 3, publish = publish })
            test.gte(summary.deferred, 2)
            test.is_false(contains(published, fresh))
            test.is_false(contains(published, deferred))
            test.is_false(contains(published, legacy))

            for _, id in ipairs({ fresh, deferred, legacy }) do
                local row = upload_repo.get(id)
                test.eq(row.status, "processing")
                local cursor = row.metadata[CURSOR]
                if cursor then
                    test.is_nil(cursor.recoveries)
                end
            end

            cleanup(fresh, deferred, legacy)
        end)

        it("gives up on a run that keeps being interrupted", function()
            local repeat_offender = make_upload("processing", {
                filename = "x.rsm",
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.ACTIVE, recoveries = 3 },
            })
            test.is_true(backdate(repeat_offender, LONG_AGO))

            local published, publish = recorder()
            local summary = recovery.recover_interrupted({ cutoff = cutoff_now(), max_attempts = 3, publish = publish })
            test.gte(summary.abandoned, 1)
            test.is_false(contains(published, repeat_offender))

            local failed = upload_repo.get(repeat_offender)
            test.eq(failed.status, "error")
            test.contains(failed.error_details, "interrupted 4 times")
            test.is_nil(failed.metadata[CURSOR], "a failed upload starts over when re-driven")

            -- With no attempts allowed the first interruption is the last.
            local once = make_upload("processing")
            test.is_true(backdate(once, LONG_AGO))
            recovery.recover_interrupted({ cutoff = cutoff_now(), max_attempts = 0, publish = publish })
            test.is_false(contains(published, once))
            local failed_once = upload_repo.get(once)
            test.eq(failed_once.status, "error")
            test.contains(failed_once.error_details, "interrupted once")

            cleanup(repeat_offender, once)
        end)

        it("keeps a re-queued upload queued when publishing fails", function()
            local id = make_upload("processing")
            test.is_true(backdate(id, LONG_AGO))

            local summary = recovery.recover_interrupted({
                cutoff = cutoff_now(),
                max_attempts = 3,
                publish = function()
                    return nil, "queue down"
                end,
            })
            test.gte(summary.errors, 1)

            -- The row is durable work for the next startup pass.
            local row = upload_repo.get(id)
            test.eq(row.status, "queued")
            test.eq(row.metadata[CURSOR].recoveries, 1)

            cleanup(id)
        end)

        it("pages through interrupted uploads without skipping any", function()
            local ids = { make_upload("processing"), make_upload("processing"), make_upload("processing") }
            for _, id in ipairs(ids) do
                test.is_true(backdate(id, LONG_AGO))
            end

            local published, publish = recorder()
            local summary = recovery.recover_interrupted({
                cutoff = cutoff_now(),
                max_attempts = 3,
                publish = publish,
                batch_size = 1,
            })
            test.gte(summary.requeued, 3)
            for _, id in ipairs(ids) do
                test.is_true(contains(published, id))
                test.eq(upload_repo.get(id).status, "queued")
            end

            cleanup(table.unpack(ids))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
