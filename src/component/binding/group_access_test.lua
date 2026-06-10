-- Group access tests: a grant whose subject is a GROUP id resolves exactly like
-- a direct user grant. Exercises the full path (binding -> reader/ops ->
-- access_subjects.resolve reading actor:meta().security_groups -> the aggregating
-- access SQL) so it is backend-agnostic and runs on both SQLite and PostgreSQL.

local test = require("test")
local sql = require("sql")
local uuid = require("uuid")
local time = require("time")
local funcs = require("funcs")
local security = require("security")

local DB = "app:db"
local GET_ACCESS = "userspace.component.binding:get_access_context_func"
local LIST = "userspace.component.binding:list_components_func"
local UPDATE = "userspace.component.binding:update_component_func"

local ACCESS = { READ = 1, WRITE = 2, DELETE = 4, ADMIN = 8, FULL = 15 }

local function define_tests()
    test.describe("Component group access", function()
        local suffix = uuid.v4():sub(1, 8)
        local grpA = "grp-A-" .. suffix  -- FULL on c_grp
        local grpR = "grp-R-" .. suffix  -- READ only on c_read
        local c_grp = uuid.v7()
        local c_read = uuid.v7()
        local c_usr = uuid.v7()
        local u_direct = "u-direct-" .. suffix

        local function db()
            local d, e = sql.get(DB)
            if e then error(tostring(e)) end
            return d
        end

        -- sql.builder keeps the data setup dialect-correct (raw "?" is sqlite-only).
        local function insert_component(cid)
            local d = db()
            local ts = time.now():format(time.RFC3339)
            local _, err = sql.builder.insert("components")
                :set_map({
                    component_id = cid,
                    impl_id = "userspace.test:grp",
                    private_context = "{}",
                    created_at = ts,
                    updated_at = ts,
                })
                :run_with(d):exec()
            d:release()
            if err then error("insert_component failed: " .. tostring(err)) end
        end

        local function grant(cid, subject, mask)
            local d = db()
            local _, err = sql.builder.insert("component_access")
                :set_map({
                    access_id = uuid.v7(),
                    component_id = cid,
                    user_id = subject,
                    access_mask = mask,
                    created_at = time.now():format(time.RFC3339),
                })
                :run_with(d):exec()
            d:release()
            if err then error("grant failed: " .. tostring(err)) end
        end

        local function cleanup()
            local d = db()
            for _, cid in ipairs({ c_grp, c_read, c_usr }) do
                sql.builder.delete("component_access"):where("component_id = ?", cid):run_with(d):exec()
                sql.builder.delete("components"):where("component_id = ?", cid):run_with(d):exec()
            end
            d:release()
        end

        -- Swap only the ACTOR identity (id + groups) that access_subjects reads,
        -- inheriting the runner's scope so the call keeps db permission. Component
        -- access is grant-based, independent of the security scope, so this does
        -- not widen what the actor can see.
        local function test_scope()
            local pol, perr = security.policy("app:test_scope_policy")
            if not pol then error("test policy missing: " .. tostring(perr)) end
            return security.new_scope({ pol })
        end

        local function run_as(user_id: string, groups: {string}, target: string, args: any)
            local actor = security.new_actor(user_id, { security_groups = groups or {} })
            return funcs.new()
                :with_actor(actor)
                :with_scope(test_scope())
                :call(target, args)
        end

        local function listed(res, cid)
            if not res or type(res.components) ~= "table" then return false end
            for _, c in ipairs(res.components) do
                if c.component_id == cid then return true end
            end
            return false
        end

        test.before_all(function()
            cleanup()
            insert_component(c_grp);  grant(c_grp, grpA, ACCESS.FULL)
            insert_component(c_read); grant(c_read, grpR, ACCESS.READ)
            insert_component(c_usr);  grant(c_usr, u_direct, ACCESS.FULL)
        end)

        test.after_all(function() cleanup() end)

        test.it("group member gains access via a group grant", function()
            local res, err = run_as("u-member", { grpA }, GET_ACCESS, { component_id = c_grp })
            test.is_nil(err)
            test.not_nil(res)
            test.is_true(res.success)
            test.eq(res.access_level, ACCESS.FULL)
        end)

        test.it("non-member is denied", function()
            local res = run_as("u-stranger", {}, GET_ACCESS, { component_id = c_grp })
            test.not_nil(res)
            test.is_false(res.success == true)
        end)

        test.it("direct user grant still works with no groups (fast path unchanged)", function()
            local res, err = run_as(u_direct, {}, GET_ACCESS, { component_id = c_usr })
            test.is_nil(err)
            test.is_true(res.success)
            test.eq(res.access_level, ACCESS.FULL)
        end)

        test.it("group access_mask is honored: READ group is excluded under a DELETE filter, included under READ", function()
            local del = run_as("u-r", { grpR }, LIST, { filters = { access_mask = ACCESS.DELETE } })
            test.is_true(del.success)
            test.is_false(listed(del, c_read))

            local rd = run_as("u-r", { grpR }, LIST, { filters = { access_mask = ACCESS.READ } })
            test.is_true(rd.success)
            test.is_true(listed(rd, c_read))
        end)

        test.it("write gate is group-aware and bitwise-correct", function()
            -- ADMIN (via FULL group grant) may GRANT_ACCESS.
            local allowed = run_as("u-admin", { grpA }, UPDATE, {
                component_id = c_grp,
                commands = { { type = "GRANT_ACCESS", payload = { user_id = "newbie-" .. suffix, access_mask = ACCESS.READ } } },
            })
            test.not_nil(allowed)
            test.is_true(allowed.changes_made == true)

            -- READ-only (via group) may NOT GRANT_ACCESS (needs ADMIN). This also
            -- guards the bitwise fix: previously any grant holder passed.
            local denied = run_as("u-readonly", { grpR }, UPDATE, {
                component_id = c_read,
                commands = { { type = "GRANT_ACCESS", payload = { user_id = "x-" .. suffix, access_mask = ACCESS.READ } } },
            })
            test.not_nil(denied)
            test.is_false(denied.success == true)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options)
    return run_cases(options)
end

return { run = run }
