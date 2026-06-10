-- access_subjects: resolve a user into the subjects (user + their groups) for a
-- component access check. Single place that expands user -> groups, used by both
-- the read path (component_reader) and the write gate (ops.check_user_access).
--
-- Fail-closed invariants:
--   * Result is always the passed user_id plus, at most, that user's groups;
--     never empty, never a wildcard.
--   * Groups are added only when user_id is the current actor; resolving for any
--     other user yields user-only (one identity's groups never apply to another).
--   * No actor / non-table meta / error -> user-only.
--   * Groups come from actor meta (the actor exposes only id() and meta()): real
--     logins set meta.security_groups, the system actor sets meta.groups; unioned.

local security = require("security")

local M = {}

local function append_groups(subjects, seen, list)
    if type(list) ~= "table" then return end
    for _, g in ipairs(list) do
        if type(g) == "string" and g ~= "" and not seen[g] then
            seen[g] = true
            subjects[#subjects + 1] = g
        end
    end
end

-- Resolve the access subjects for user_id. Returns { user_id, group1, ... }.
function M.resolve(user_id)
    local subjects = { user_id }
    if type(user_id) ~= "string" or user_id == "" then
        return subjects
    end

    local ok_actor, actor = pcall(security.actor)
    if not ok_actor or not actor then
        return subjects
    end

    local ok_id, actor_id = pcall(function() return actor:id() end)
    if not ok_id or actor_id ~= user_id then
        -- Not the current actor: never borrow another identity's groups.
        return subjects
    end

    local ok_meta, meta = pcall(function() return actor:meta() end)
    if not ok_meta or type(meta) ~= "table" then
        return subjects
    end

    local seen = { [user_id] = true }
    append_groups(subjects, seen, meta.security_groups)
    append_groups(subjects, seen, meta.groups)
    return subjects
end

-- Build a parameterized "?,?,..." placeholder string for a subject list.
function M.placeholders(subjects)
    local marks = {}
    for i = 1, #subjects do
        marks[i] = "?"
    end
    return table.concat(marks, ",")
end

return M
