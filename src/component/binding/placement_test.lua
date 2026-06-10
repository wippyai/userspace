-- Placement tests: hierarchy registration, list_children ordering, re-parenting
-- with path re-materialization, cycle rejection, lexorank reorder, ON DELETE SET
-- NULL orphaning, subtree grant/revoke (including group resolution), and
-- backward-compat of plain register/list. Runs on SQLite and PostgreSQL.

local test = require("test")
local sql = require("sql")
local uuid = require("uuid")
local time = require("time")
local funcs = require("funcs")
local security = require("security")

local DB = "app:db"
local REGISTER = "userspace.component.binding:register_component_func"
local SET_PLACEMENT = "userspace.component.binding:set_placement_func"
local LIST_CHILDREN = "userspace.component.binding:list_children_func"
local GET_COMPONENT = "userspace.component.binding:get_component_func"
local GET_ACCESS = "userspace.component.binding:get_access_context_func"
local LIST = "userspace.component.binding:list_components_func"
local GRANT_SUBTREE = "userspace.component.binding:grant_subtree_func"
local REVOKE_SUBTREE = "userspace.component.binding:revoke_subtree_func"

local ACCESS = { READ = 1, WRITE = 2, DELETE = 4, ADMIN = 8, FULL = 15 }

local function define_tests()
    test.describe("Component placement", function()
        local suffix = uuid.v4():sub(1, 8)
        local owner = "owner-" .. suffix
        local impl = "userspace.test:placement"

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

        -- Owner-scoped call helper (the actor that holds FULL access).
        local function as_owner(target, args)
            return run_as(owner, {}, target, args)
        end

        -- Read a stored row directly for path assertions.
        local function read_row(cid)
            local d, e = sql.get(DB)
            if e then error(tostring(e)) end
            local rows, qerr = sql.builder.select("component_id", "parent_id", "position", "path")
                :from("components")
                :where("component_id = ?", cid)
                :run_with(d):query()
            d:release()
            if qerr then error(tostring(qerr)) end
            return rows and rows[1] or nil
        end

        local function register(parent_id, position)
            local res, err = as_owner(REGISTER, {
                impl_id = impl,
                meta = { class = "placement_test" },
                parent_id = parent_id,
                position = position
            })
            if err then error("register call failed: " .. tostring(err)) end
            if not res or not res.success then
                error("register failed: " .. tostring(res and res.error))
            end
            return res.component_id
        end

        local function child_ids(res)
            local ids = {}
            if res and type(res.components) == "table" then
                for _, c in ipairs(res.components) do
                    ids[#ids + 1] = c.component_id
                end
            end
            return ids
        end

        local function index_of(list, v)
            for i, x in ipairs(list) do
                if x == v then return i end
            end
            return nil
        end

        test.it("registers without parent at root and lists under root", function()
            local root_id = register(nil, nil)
            local row = read_row(root_id)
            test.not_nil(row)
            test.is_nil(row.parent_id)
            test.not_nil(row.path)

            local res = as_owner(LIST_CHILDREN, { parent_id = nil })
            test.is_true(res.success)
            test.is_true(index_of(child_ids(res), root_id) ~= nil)
        end)

        test.it("registers with parent and appears under list_children of that parent", function()
            local parent_id = register(nil, nil)
            local kid_id = register(parent_id, nil)

            local row = read_row(kid_id)
            test.eq(row.parent_id, parent_id)

            local res = as_owner(LIST_CHILDREN, { parent_id = parent_id })
            test.is_true(res.success)
            test.is_true(index_of(child_ids(res), kid_id) ~= nil)

            -- Child must NOT appear at root.
            local root_res = as_owner(LIST_CHILDREN, { parent_id = nil })
            test.is_false(index_of(child_ids(root_res), kid_id) ~= nil)
        end)

        test.it("moving re-parents and re-materializes a grandchild path", function()
            local a = register(nil, nil)
            local b = register(nil, nil)
            local child = register(a, nil)
            local grandchild = register(child, nil)

            -- child's grandchild path descends from a.
            local gc_before = read_row(grandchild)
            local a_row = read_row(a)
            test.not_nil(gc_before.path)

            -- Move child (with grandchild) under b.
            local res, err = as_owner(SET_PLACEMENT, { component_id = child, parent_id = b })
            test.is_nil(err)
            test.is_true(res.success)
            test.eq(res.parent_id, b)

            local child_after = read_row(child)
            local gc_after = read_row(grandchild)
            local b_row = read_row(b)

            test.eq(child_after.parent_id, b)
            -- Grandchild path must now descend from b's path, not a's.
            test.is_true(tostring(gc_after.path):find(tostring(b_row.path), 1, true) == 1)
            -- Concretely: grandchild no longer under a.
            local a_prefix
            if tostring(a_row.path):find("/", 1, true) then
                a_prefix = tostring(a_row.path)
            else
                a_prefix = tostring(a_row.path) .. "."
            end
            test.is_false(tostring(gc_after.path):find(a_prefix, 1, true) == 1)
        end)

        test.it("rejects a cycle and leaves the tree unchanged", function()
            local a = register(nil, nil)
            local child = register(a, nil)
            local grandchild = register(child, nil)

            local before = read_row(a)

            -- Move a under its own grandchild -> INVALID.
            local res = as_owner(SET_PLACEMENT, { component_id = a, parent_id = grandchild })
            test.not_nil(res)
            test.is_false(res.success == true)
            test.eq(res.kind, "Invalid")

            -- a unchanged (still root).
            local after = read_row(a)
            test.is_nil(after.parent_id)
            test.eq(tostring(after.path), tostring(before.path))

            -- Move a under itself -> INVALID too.
            local self_res = as_owner(SET_PLACEMENT, { component_id = a, parent_id = a })
            test.is_false(self_res.success == true)
            test.eq(self_res.kind, "Invalid")
        end)

        test.it("lexorank reorder: insert between, at head, and at tail", function()
            local parent = register(nil, nil)
            local c1 = register(parent, nil) -- appended
            local c2 = register(parent, nil) -- appended after c1

            local r1 = read_row(c1)
            local r2 = read_row(c2)
            test.is_true(tostring(r1.position) < tostring(r2.position))

            -- Compute a midpoint between c1 and c2 and place a new node there.
            local placement = require("placement") :: any
            local mid = placement.rank_between(tostring(r1.position), tostring(r2.position))
            test.is_true(tostring(r1.position) < mid)
            test.is_true(mid < tostring(r2.position))

            local c_mid = register(parent, mid)

            -- Head: strictly before c1.
            local head = placement.rank_between(nil, tostring(r1.position))
            test.is_true(head < tostring(r1.position))
            local c_head = register(parent, head)

            -- Tail: register without position appends after the current max.
            local c_tail = register(parent, nil)

            local res = as_owner(LIST_CHILDREN, { parent_id = parent })
            test.is_true(res.success)
            local ids = child_ids(res)
            -- Expected order: head, c1, mid, c2, tail
            local i_head = index_of(ids, c_head)
            local i_c1 = index_of(ids, c1)
            local i_mid = index_of(ids, c_mid)
            local i_c2 = index_of(ids, c2)
            local i_tail = index_of(ids, c_tail)
            test.not_nil(i_head)
            test.is_true(i_head < i_c1)
            test.is_true(i_c1 < i_mid)
            test.is_true(i_mid < i_c2)
            test.is_true(i_c2 < i_tail)
        end)

        test.it("ON DELETE SET NULL orphans children to root", function()
            local parent = register(nil, nil)
            local kid = register(parent, nil)
            local grandkid = register(kid, nil)

            -- Delete the parent through the service (DELETE access held by owner).
            local del = as_owner("userspace.component.binding:delete_component_func", { component_id = parent })
            test.is_true(del.success)

            -- kid is orphaned to root: parent_id NULL, path re-rooted.
            local kid_row = read_row(kid)
            test.not_nil(kid_row)
            test.is_nil(kid_row.parent_id)

            -- Grandkid still descends from kid's new root path.
            local gk_row = read_row(grandkid)
            test.not_nil(gk_row)
            test.is_true(tostring(gk_row.path):find(tostring(kid_row.path), 1, true) == 1)

            -- kid now appears at root in list_children.
            local res = as_owner(LIST_CHILDREN, { parent_id = nil })
            test.is_true(index_of(child_ids(res), kid) ~= nil)
        end)

        test.it("grant_subtree gives READ on a deep descendant; revoke_subtree removes it", function()
            local root = register(nil, nil)
            local mid = register(root, nil)
            local leaf = register(mid, nil)

            local viewer = "viewer-" .. suffix

            -- Before grant: viewer cannot read the leaf.
            local before = run_as(viewer, {}, GET_ACCESS, { component_id = leaf })
            test.is_false(before.success == true)

            local g = as_owner(GRANT_SUBTREE, {
                root_component_id = root,
                subject = { user_id = viewer },
                access_mask = ACCESS.READ
            })
            test.is_true(g.success)
            test.is_true(g.affected >= 3)

            local after = run_as(viewer, {}, GET_ACCESS, { component_id = leaf })
            test.is_true(after.success)
            test.eq(after.access_level, ACCESS.READ)

            local r = as_owner(REVOKE_SUBTREE, {
                root_component_id = root,
                subject = { user_id = viewer }
            })
            test.is_true(r.success)

            local revoked = run_as(viewer, {}, GET_ACCESS, { component_id = leaf })
            test.is_false(revoked.success == true)
        end)

        test.it("subtree group grant resolves for a member; non-members excluded", function()
            local root = register(nil, nil)
            local leaf = register(root, nil)
            local grp = "grp-sub-" .. suffix

            local g = as_owner(GRANT_SUBTREE, {
                root_component_id = root,
                subject = { group_id = grp },
                access_mask = ACCESS.READ
            })
            test.is_true(g.success)

            -- Member of the group reads the leaf via group resolution.
            local member = run_as("member-" .. suffix, { grp }, GET_ACCESS, { component_id = leaf })
            test.is_true(member.success)
            test.eq(member.access_level, ACCESS.READ)

            -- Non-member is excluded.
            local stranger = run_as("stranger-" .. suffix, {}, GET_ACCESS, { component_id = leaf })
            test.is_false(stranger.success == true)
        end)

        test.it("backward compat: plain register (no placement) and list still work", function()
            local res, err = as_owner(REGISTER, { impl_id = impl, meta = { class = "compat" } })
            test.is_nil(err)
            test.is_true(res.success)
            local cid = res.component_id

            local row = read_row(cid)
            test.is_nil(row.parent_id)
            test.not_nil(row.position)
            test.not_nil(row.path)

            local listed = as_owner(LIST, { filters = { meta = { class = "compat" } } })
            test.is_true(listed.success)
            local found = false
            for _, c in ipairs(listed.components) do
                if c.component_id == cid then found = true end
            end
            test.is_true(found)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options)
    return run_cases(options)
end

return { run = run }
