local test = require("test")
local sql = require("sql")
local time = require("time")
local uuid = require("uuid")
local dispatch = require("dispatch")
local recovery = require("recovery")
local upload_lib = require("upload_lib")
local upload_repo = require("upload_repo")
local pipeline_lib = require("pipeline_lib")

local RESUME_TYPE = "app:type.resumable"
local FIFO = dispatch.STRATEGY.FIFO
local FAIR = dispatch.STRATEGY.FAIR
local CURSOR = pipeline_lib.CURSOR_KEY
local STATE = pipeline_lib.CURSOR_STATE
local LONG_AGO = "2000-01-01T00:00:00Z"

local function new_user()
    return "user-" .. uuid.v4()
end

-- Timestamps are stamped to the second, so tests that depend on who has waited
-- longest set the wait explicitly.
local function stamp(id, when)
    local db, err = sql.get("app:db")
    if err then
        return nil, err
    end
    local _, exec_err = sql.builder.update("uploads")
        :set("created_at", when)
        :set("updated_at", when)
        :where("uuid = ?", id)
        :run_with(db)
        :exec()
    db:release()
    return exec_err == nil, exec_err
end

local function make_upload(user_id, status, waiting_since, metadata)
    local id = uuid.v4()
    local _, err = upload_repo.create(
        id, user_id, 10, "application/x-resume-test",
        "app:uploads", id .. ".rsm", RESUME_TYPE, metadata or { filename = "x.rsm" },
        status or "uploaded"
    )
    if err then
        error(err)
    end
    if waiting_since then
        local stamped = stamp(id, waiting_since)
        test.is_true(stamped)
    end
    return id
end

local function expect_nobody_waiting()
    local user_id, err = upload_repo.next_turn()
    test.is_nil(err)
    test.is_nil(user_id, "another suite left an upload waiting: " .. tostring(user_id))
end

local function counter()
    local n = 0
    return function()
        n = n + 1
        return n
    end
end

local function no_pause()
end

local function cleanup(...)
    for _, id in ipairs({ ... }) do
        upload_repo.delete(id)
    end
end

local function define_tests()
    describe("Dispatch settings", function()
        it("reads fifo or fair and falls back to fifo", function()
            test.eq(dispatch.parse_strategy(nil), FIFO)
            test.eq(dispatch.parse_strategy(""), FIFO)
            test.eq(dispatch.parse_strategy("  "), FIFO)
            test.eq(dispatch.parse_strategy("fair"), FAIR)
            test.eq(dispatch.parse_strategy(" FAIR "), FAIR)
            test.eq(dispatch.parse_strategy("fifo"), FIFO)

            local strategy, err = dispatch.parse_strategy("round-robin")
            test.is_nil(strategy)
            test.contains(err, "queue_strategy")

            test.eq(dispatch.load_strategy(), FIFO, "nothing configured means fifo")
        end)

        it("stamps turns finer than a second", function()
            local before = dispatch.turn_now()
            test.is_true(before > time.now():unix() * 1000000 - 1000000)
            time.sleep("2ms")
            test.is_true(dispatch.turn_now() > before)
        end)
    end)

    describe("Turn repository", function()
        it("records a turn once per user and keeps the latest", function()
            local user = new_user()
            test.is_nil(upload_repo.turn_of(user))

            test.eq(upload_repo.record_turn(user, 10), true)
            test.eq(upload_repo.turn_of(user), 10)

            test.eq(upload_repo.record_turn(user, 25), true)
            test.eq(upload_repo.turn_of(user), 25)

            local _, no_user = upload_repo.record_turn(nil, 1)
            test.eq(no_user, "User ID is required")
            local _, no_turn = upload_repo.record_turn(user, "now")
            test.contains(no_turn, "served_at")
        end)

        it("claims a waiting upload exactly once", function()
            local user = new_user()
            local uploaded = make_upload(user, "uploaded")
            local queued = make_upload(user, "queued")
            local processing = make_upload(user, "processing")
            local pending = make_upload(user, "pending")

            test.eq(upload_repo.claim(uploaded), true)
            test.eq(upload_repo.get(uploaded).status, "processing")
            test.eq(upload_repo.claim(uploaded), false, "already taken")

            test.eq(upload_repo.claim(queued), true)
            test.eq(upload_repo.claim(processing), false)
            test.eq(upload_repo.claim(pending), false)

            local _, no_id = upload_repo.claim("")
            test.eq(no_id, "Upload ID is required")

            cleanup(uploaded, queued, processing, pending)
        end)

        it("finds the upload a user has had in line longest", function()
            local user = new_user()
            local newer = make_upload(user, "uploaded", "2001-01-01T00:00:02Z")
            local older = make_upload(user, "queued", "2001-01-01T00:00:01Z")
            local taken = make_upload(user, "processing", "2001-01-01T00:00:00Z")

            local first = upload_repo.oldest_pending(user)
            test.eq(first.uuid, older)
            test.is_table(first.metadata)

            test.eq(upload_repo.claim(older), true)
            test.eq(upload_repo.oldest_pending(user).uuid, newer)

            test.eq(upload_repo.claim(newer), true)
            test.is_nil(upload_repo.oldest_pending(user))

            local _, no_user = upload_repo.oldest_pending("")
            test.eq(no_user, "User ID is required")

            cleanup(newer, older, taken)
        end)

        it("re-queues anything but a presigned upload still in flight", function()
            local user = new_user()
            local processing = make_upload(user, "processing")
            local failed = make_upload(user, "error")
            local completed = make_upload(user, "completed")
            local pending = make_upload(user, "pending")

            for _, id in ipairs({ processing, failed, completed }) do
                test.eq(upload_repo.mark_queued(id), true)
                test.eq(upload_repo.get(id).status, "queued")
            end

            test.eq(upload_repo.mark_queued(pending), false)
            test.eq(upload_repo.get(pending).status, "pending")
            test.eq(upload_repo.mark_queued(uuid.v4()), false)

            local _, no_id = upload_repo.mark_queued(nil)
            test.eq(no_id, "Upload ID is required")

            cleanup(processing, failed, completed, pending)
        end)

        it("leaves a running upload alone when asked to", function()
            local user = new_user()
            local running = make_upload(user, "processing")
            local stale = make_upload(user, "processing", LONG_AGO)
            local failed = make_upload(user, "error")
            local cutoff = recovery.cutoff(time.now(), time.parse_duration("1m"))

            test.eq(upload_repo.mark_queued(running, { stale_before = cutoff }), false)
            test.eq(upload_repo.get(running).status, "processing")

            test.eq(upload_repo.mark_queued(stale, { stale_before = cutoff }), true)
            test.eq(upload_repo.mark_queued(failed, { stale_before = cutoff }), true)

            cleanup(running, stale, failed)
        end)

        it("lists waiting uploads untouched since the cutoff", function()
            local user = new_user()
            local stale = make_upload(user, "uploaded", LONG_AGO)
            local stale_queued = make_upload(user, "queued", LONG_AGO)
            local fresh = make_upload(user, "uploaded")
            local stale_processing = make_upload(user, "processing", LONG_AGO)
            local cutoff = recovery.cutoff(time.now(), time.parse_duration("1m"))

            local seen = {}
            local after = nil
            while true do
                local rows, err = upload_repo.list_stale_pending(cutoff, after, 1)
                test.is_nil(err)
                if #rows == 0 then
                    break
                end
                if after then
                    test.is_true(rows[1].uuid > after, "pages must advance by uuid")
                end
                seen[rows[1].uuid] = true
                after = rows[1].uuid
            end

            test.is_true(seen[stale])
            test.is_true(seen[stale_queued])
            test.is_nil(seen[fresh])
            test.is_nil(seen[stale_processing])

            local _, no_cutoff = upload_repo.list_stale_pending(nil)
            test.eq(no_cutoff, "Cutoff is required")

            cleanup(stale, stale_queued, fresh, stale_processing)
        end)

        it("gives the turn to whoever was served longest ago", function()
            expect_nobody_waiting()
            local a, b = new_user(), new_user()
            local a1 = make_upload(a, "uploaded", "2001-01-01T00:00:02Z")
            local b1 = make_upload(b, "uploaded", "2001-01-01T00:00:01Z")
            local parked = make_upload(new_user(), "pending", "2000-01-01T00:00:00Z")

            test.eq(upload_repo.next_turn(), b, "never served: the longest wait goes first")

            test.eq(upload_repo.record_turn(b, 10), true)
            test.eq(upload_repo.next_turn(), a, "never served beats served")

            test.eq(upload_repo.record_turn(a, 20), true)
            test.eq(upload_repo.next_turn(), b, "served earlier goes before served later")

            test.eq(upload_repo.claim(b1), true)
            test.eq(upload_repo.next_turn(), a, "a user with nothing waiting has no turn")

            test.eq(upload_repo.claim(a1), true)
            test.is_nil(upload_repo.next_turn(), "a presigned upload still in flight is not waiting")

            cleanup(a1, b1, parked)
        end)
    end)

    describe("Fair dispatch", function()
        it("serves users in turns, longest in line first", function()
            expect_nobody_waiting()
            local a, b = new_user(), new_user()
            local a1 = make_upload(a, "uploaded", "2001-01-01T00:00:01Z")
            local a2 = make_upload(a, "uploaded", "2001-01-01T00:00:02Z")
            local a3 = make_upload(a, "uploaded", "2001-01-01T00:00:03Z")
            local b1 = make_upload(b, "uploaded", "2001-01-01T00:00:04Z")

            local turn = counter()
            local claimed = {}
            for _ = 1, 4 do
                local upload, err = dispatch.claim_next({ turn = turn })
                test.is_nil(err)
                claimed[#claimed + 1] = test.is_table(upload)
                test.eq(upload.status, "processing")
                test.eq(upload_repo.get(upload.uuid).status, "processing")
            end

            test.eq(claimed[1].uuid, a1, "both never served: the longest wait goes first")
            test.eq(claimed[2].uuid, b1, "then the user who has not had a turn")
            test.eq(claimed[3].uuid, a2, "then the user served longest ago")
            test.eq(claimed[4].uuid, a3, "a user alone in line keeps going")

            test.eq(upload_repo.turn_of(a), 4)
            test.eq(upload_repo.turn_of(b), 2)

            local nothing, err = dispatch.claim_next({ turn = turn })
            test.is_nil(nothing)
            test.is_nil(err, "an empty line is not an error")

            cleanup(a1, a2, a3, b1)
        end)

        it("sends a re-driven document to the back of its owner's line", function()
            expect_nobody_waiting()
            local user = new_user()
            local fresh = make_upload(user, "uploaded", recovery.cutoff(time.now(), time.parse_duration("1m")))
            local old = make_upload(user, "completed", "2001-01-01T00:00:01Z")

            test.eq(upload_lib.requeue(old, { publish = function() return true end }), true)

            local first = test.is_table(dispatch.claim_next({ pause = no_pause }))
            test.eq(first.uuid, fresh, "the fresh upload was in line first")
            local second = test.is_table(dispatch.claim_next({ pause = no_pause }))
            test.eq(second.uuid, old)

            cleanup(fresh, old)
        end)

        it("looks again after losing a race instead of giving the token back", function()
            expect_nobody_waiting()
            local user = new_user()
            local id = make_upload(user, "uploaded")

            local lost = 0
            local pauses = 0
            local upload, err = dispatch.claim_next({
                pause = function()
                    pauses = pauses + 1
                end,
                claim = function(upload_id)
                    if lost < 3 then
                        lost = lost + 1
                        return false
                    end
                    return upload_repo.claim(upload_id)
                end,
            })
            test.is_nil(err)
            test.eq(upload.uuid, id)
            test.eq(lost, 3)
            test.eq(pauses, 3, "every lost race pauses before looking again")
            test.eq(upload_repo.get(id).status, "processing")

            cleanup(id)
        end)

        it("gives the token back only after a long run of lost races", function()
            local user = new_user()
            local id = make_upload(user, "uploaded")

            local upload, err = dispatch.claim_next({
                attempts = 2,
                pause = no_pause,
                claim = function()
                    return false
                end,
            })
            test.is_nil(upload)
            test.contains(err, "2 attempts")
            test.eq(upload_repo.get(id).status, "uploaded")
            test.is_nil(upload_repo.turn_of(user), "a lost claim is not a turn")

            cleanup(id)
        end)

        it("retries a failing database with a pause before giving up", function()
            local user = new_user()
            local id = make_upload(user, "uploaded")

            local failures = 0
            local pauses = 0
            local upload, err = dispatch.claim_next({
                error_attempts = 3,
                pause = function()
                    pauses = pauses + 1
                end,
                claim = function()
                    failures = failures + 1
                    return nil, "database down"
                end,
            })
            test.is_nil(upload)
            test.eq(err, "database down")
            test.eq(failures, 3)
            test.eq(pauses, 3, "every database error pauses before the retry")

            local recovered = 0
            local healed = dispatch.claim_next({
                error_attempts = 3,
                pause = no_pause,
                claim = function(upload_id)
                    recovered = recovered + 1
                    if recovered == 1 then
                        return nil, "database down"
                    end
                    return upload_repo.claim(upload_id)
                end,
            })
            test.eq(healed.uuid, id, "one failure is not the end")

            cleanup(id)
        end)

        it("keeps a claimed upload when the turn cannot be recorded", function()
            local user = new_user()
            local id = make_upload(user, "uploaded")

            local upload, err = dispatch.claim_next({
                pause = no_pause,
                record_turn = function()
                    return nil, "turns table missing"
                end,
            })
            test.is_nil(err)
            test.eq(upload.uuid, id)
            test.eq(upload_repo.get(id).status, "processing")
            test.is_nil(upload_repo.turn_of(user))

            cleanup(id)
        end)

        it("runs the named upload in fifo and whoever's turn it is in fair", function()
            expect_nobody_waiting()
            local a, b = new_user(), new_user()
            local a1 = make_upload(a, "uploaded", "2001-01-01T00:00:01Z")
            local b1 = make_upload(b, "uploaded", "2001-01-01T00:00:02Z")

            local named, named_err = dispatch.pick(b1, FIFO)
            test.is_nil(named_err)
            test.eq(named.uuid, b1)
            test.eq(upload_repo.get(b1).status, "uploaded", "fifo leaves claiming to the pipeline")

            local missing, missing_err = dispatch.pick(uuid.v4(), FIFO)
            test.is_nil(missing)
            test.is_nil(missing_err, "an unknown upload is skipped, not retried")

            local first, first_err = dispatch.pick(b1, FAIR)
            test.is_nil(first_err)
            test.eq(first.uuid, a1, "the message is a token; the longest wait runs first")
            test.eq(upload_repo.get(a1).status, "processing")

            local second = dispatch.pick(b1, FAIR)
            test.eq(second.uuid, b1)

            local third, third_err = dispatch.pick(b1, FAIR)
            test.is_nil(third)
            test.is_nil(third_err)

            cleanup(a1, b1)
        end)

        it("hands a claimed upload to the pipeline", function()
            expect_nobody_waiting()
            local id = make_upload(new_user(), "uploaded")

            local upload = test.is_table(dispatch.claim_next({ pause = no_pause }))
            test.eq(upload.uuid, id)
            test.eq(pipeline_lib.process_upload(upload), true)

            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            test.eq(done.metadata.stage_one_runs, 1)
            test.eq(done.metadata.stage_two_runs, 1)
            test.eq(done.metadata.stage_three_runs, 1)

            cleanup(id)
        end)
    end)

    describe("Requeue", function()
        local function recorder()
            local published = {}
            return published, function(upload_id)
                published[#published + 1] = upload_id
                return true
            end
        end

        it("puts an upload back in line and publishes one token", function()
            local id = make_upload(new_user(), "completed")

            local published, publish = recorder()
            local ok, err = upload_lib.requeue(id, { publish = publish })
            test.is_nil(err)
            test.eq(ok, true)
            test.eq(upload_repo.get(id).status, "queued")
            test.eq(#published, 1)
            test.eq(published[1], id)

            local live, live_err = upload_lib.requeue(id)
            test.is_nil(live_err, "the default publisher reaches the queue")
            test.eq(live, true)

            cleanup(id)
        end)

        it("keeps the row queued when publishing fails", function()
            local id = make_upload(new_user(), "error")

            local ok, err = upload_lib.requeue(id, {
                publish = function()
                    return nil, "queue down"
                end,
            })
            test.is_nil(ok)
            test.contains(err, "queue down")
            test.eq(upload_repo.get(id).status, "queued", "durable work for the startup pass of recovery")

            cleanup(id)
        end)

        it("refuses a running upload unless it is parked or stale", function()
            local user = new_user()
            local running = make_upload(user, "processing", nil, {
                filename = "x.rsm",
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.ACTIVE },
            })
            local first_stage = make_upload(user, "processing")
            local parked = make_upload(user, "processing", nil, {
                filename = "x.rsm",
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.DEFERRED },
            })
            local stale = make_upload(user, "processing", LONG_AGO, {
                filename = "x.rsm",
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.ACTIVE },
            })

            local published, publish = recorder()

            local ok, err = upload_lib.requeue(running, { publish = publish })
            test.is_nil(ok)
            test.contains(err, "still being processed")
            test.eq(upload_repo.get(running).status, "processing")

            local _, first_err = upload_lib.requeue(first_stage, { publish = publish })
            test.contains(first_err, "still being processed")
            test.eq(#published, 0)

            test.eq(upload_lib.requeue(parked, { publish = publish }), true)
            test.eq(upload_repo.get(parked).status, "queued")

            test.eq(upload_lib.requeue(stale, { publish = publish }), true)
            test.eq(upload_repo.get(stale).status, "queued")

            test.eq(upload_lib.requeue(running, { publish = publish, force = true }), true)
            test.eq(upload_repo.get(running).status, "queued")
            test.eq(#published, 3)

            cleanup(running, first_stage, parked, stale)
        end)

        it("needs force once the caller has written to a parked upload", function()
            local id = make_upload(new_user(), "processing", LONG_AGO, {
                filename = "x.rsm",
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.DEFERRED },
            })
            local published, publish = recorder()

            local before = test.is_table(upload_repo.get(id))
            test.is_table(upload_repo.update_metadata(id, { filename = "x.rsm", password_required = false }))
            test.is_true(tostring(upload_repo.get(id).updated_at) > tostring(before.updated_at))

            local ok, err = upload_lib.requeue(id, { publish = publish })
            test.is_nil(ok)
            test.contains(err, "still being processed")
            test.eq(upload_repo.get(id).status, "processing")

            test.eq(upload_lib.requeue(id, { publish = publish, force = true }), true)
            test.eq(upload_repo.get(id).status, "queued")
            test.eq(#published, 1)

            cleanup(id)
        end)

        it("marks a resumed stage active before running it", function()
            local id = make_upload(new_user(), "processing", nil, {
                filename = "x.rsm",
                stage_one_runs = 1,
                [CURSOR] = { index = 2, func = "app:stage_two", state = STATE.DEFERRED, recoveries = 1 },
            })

            test.eq(pipeline_lib.process_upload(upload_repo.get(id)), true)

            local done = upload_repo.get(id)
            test.eq(done.status, "completed")
            test.eq(done.metadata.stage_one_runs, 1, "stage one must not run again")
            test.eq(done.metadata.stage_two_runs, 1)
            local saw = test.is_table(done.metadata.stage_two_saw_cursor)
            test.eq(saw.state, STATE.ACTIVE, "the stage runs under an active cursor, not a parked one")
            test.eq(saw.index, 2)
            test.eq(saw.recoveries, 1)
            test.is_nil(done.metadata[CURSOR])

            cleanup(id)
        end)

        it("refuses what cannot wait in line", function()
            local pending = make_upload(new_user(), "pending")

            local ok, err = upload_lib.requeue(pending)
            test.is_nil(ok)
            test.contains(err, "cannot be queued")
            test.eq(upload_repo.get(pending).status, "pending")

            local _, unknown = upload_lib.requeue(uuid.v4())
            test.contains(unknown, "cannot be queued")

            local _, no_id = upload_lib.requeue("")
            test.eq(no_id, "Upload ID is required")

            cleanup(pending)
        end)
    end)

    describe("Lost tokens", function()
        local function recorder()
            local published = {}
            return published, function(upload_id)
                published[#published + 1] = upload_id
                return true
            end
        end

        local function cutoff_now()
            return recovery.cutoff(time.now(), time.parse_duration("1m"))
        end

        it("re-publishes waiting uploads nobody came for, only while the queue is empty", function()
            local user = new_user()
            local forgotten = make_upload(user, "uploaded", LONG_AGO)
            local forgotten_queued = make_upload(user, "queued", LONG_AGO)
            local fresh = make_upload(user, "uploaded")
            local running = make_upload(user, "processing", LONG_AGO)

            local published, publish = recorder()
            local busy = recovery.republish_lost(publish, {
                cutoff = cutoff_now(),
                depth = function()
                    return 3
                end,
            })
            test.eq(busy.skipped, true)
            test.eq(#published, 0)

            local unknown = recovery.republish_lost(publish, {
                cutoff = cutoff_now(),
                depth = function()
                    return nil
                end,
            })
            test.eq(unknown.skipped, true)

            local idle = recovery.republish_lost(publish, {
                cutoff = cutoff_now(),
                depth = function()
                    return 0
                end,
            })
            test.eq(idle.skipped, false)
            test.gte(idle.published, 2)
            test.eq(idle.errors, 0)

            local seen = {}
            for _, id in ipairs(published) do
                seen[id] = true
            end
            test.is_true(seen[forgotten])
            test.is_true(seen[forgotten_queued])
            test.is_nil(seen[fresh])
            test.is_nil(seen[running])

            local _, no_cutoff = recovery.republish_lost(publish, { depth = function() return 0 end })
            test.eq(no_cutoff, "Cutoff is required")

            cleanup(forgotten, forgotten_queued, fresh, running)
        end)

        it("stops at the per-pass limit and counts publish failures", function()
            local user = new_user()
            local ids = {
                make_upload(user, "uploaded", LONG_AGO),
                make_upload(user, "uploaded", LONG_AGO),
                make_upload(user, "uploaded", LONG_AGO),
            }

            local published, publish = recorder()
            local capped = recovery.republish_lost(publish, {
                cutoff = cutoff_now(),
                depth = function()
                    return 0
                end,
                limit = 2,
                batch_size = 1,
            })
            test.eq(capped.published, 2)
            test.eq(#published, 2)

            local failing = recovery.republish_lost(function()
                return nil, "queue down"
            end, {
                cutoff = cutoff_now(),
                depth = function()
                    return 0
                end,
                limit = 2,
            })
            test.eq(failing.published, 0)
            test.eq(failing.errors, 2)

            cleanup(table.unpack(ids))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
