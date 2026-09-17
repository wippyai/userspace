local test = require("test")
local sql = require("sql")
local time = require("time")
local runner = require("runner")

local DB = "app:db"
local LOG_CURSOR_MIGRATION = "userspace.docker.migrations:04_add_stdin_operations"

local function db_handle()
    local db, err = sql.get(DB)
    if err then
        error("failed to connect to " .. DB .. ": " .. tostring(err))
    end
    return db
end

local function is_applied(r, id: string): boolean
    local status = r:status()
    for _, m in ipairs(status.migrations or {}) do
        if m.id == id then
            return m.status == "applied"
        end
    end
    error("migration not registered: " .. id)
end

local function define_tests()
    describe("container log cursor migration", function()
        it("backfills contiguous per-container sequences for large histories quickly", function()
            local r = runner.setup(DB)

            -- Revert to the schema before per-container cursors existed.
            local guard = 0
            while is_applied(r, LOG_CURSOR_MIGRATION) do
                guard = guard + 1
                if guard > 10 then error("log cursor migration did not roll back") end
                local _, rollback_err = r:rollback()
                if rollback_err then error("rollback failed: " .. tostring(rollback_err)) end
            end

            local db = db_handle()
            local columns = db:query("PRAGMA table_info(container_logs)")
            for _, col in ipairs(columns or {}) do
                test.ok(col.name ~= "sequence", "sequence column removed before backfill")
            end

            local histories = { ["mig-large"] = 120000, ["mig-small"] = 25, ["mig-medium"] = 4000 }
            -- Two interleaved passes so each container's rows are split across the id space.
            local order = { "mig-large", "mig-small", "mig-medium", "mig-large", "mig-small", "mig-medium" }
            local written = {}
            for _, cid in ipairs(order) do
                local total = histories[cid]
                local done = written[cid] or 0
                local target = done == 0 and math.floor(total / 2) or total
                while done < target do
                    local rows = {}
                    local params = {}
                    local chunk = math.min(400, target - done)
                    for i = 1, chunk do
                        table.insert(rows, "(?, 'stdout', ?, 1)")
                        table.insert(params, cid)
                        table.insert(params, "line " .. (done + i))
                    end
                    local _, err = db:execute("INSERT INTO container_logs (container_id, stream, line, ts) VALUES "
                        .. table.concat(rows, ", "), params)
                    if err then error("seed insert failed: " .. tostring(err)) end
                    done = done + chunk
                end
                written[cid] = done
            end
            db:release()

            local started = time.now()
            local _, run_err = r:run()
            local elapsed = time.now():sub(started):seconds()
            test.is_nil(run_err, "pending migrations applied")
            test.is_true(is_applied(r, LOG_CURSOR_MIGRATION), "log cursor migration applied")
            test.ok(elapsed < 10, string.format("backfill of %d rows finished in %.1fs", 124025, elapsed))

            db = db_handle()
            for cid, total in pairs(histories) do
                local stats = db:query([[
                    SELECT COUNT(*) AS n, MIN(sequence) AS lo, MAX(sequence) AS hi, COUNT(DISTINCT sequence) AS distinct_n
                    FROM container_logs WHERE container_id = ?
                ]], { cid })
                local s = stats[1]
                test.eq(tonumber(s.n), total, cid .. " row count")
                test.eq(tonumber(s.lo), 1, cid .. " sequence starts at 1")
                test.eq(tonumber(s.hi), total, cid .. " sequence ends at its row count")
                test.eq(tonumber(s.distinct_n), total, cid .. " sequences are unique")

                local misordered = db:query([[
                    SELECT COUNT(*) AS n FROM container_logs a
                    JOIN container_logs b ON a.container_id = b.container_id AND b.sequence = a.sequence + 1
                    WHERE a.container_id = ? AND b.id < a.id
                ]], { cid })
                test.eq(tonumber(misordered[1].n), 0, cid .. " sequence follows insertion order")
            end
            db:execute("DELETE FROM container_logs WHERE container_id IN ('mig-large', 'mig-small', 'mig-medium')")
            db:release()
        end)
    end)
end

return test.run_cases(define_tests)
