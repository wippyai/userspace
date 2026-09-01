local sql = require("sql")
local env = require("env")
local consts = require("consts")
local containers_repo = require("containers_repo")

local function handle(input: {operation_id: string})
    if not input.operation_id or input.operation_id == "" then
        return { success = false, error = "operation_id is required" }
    end
    local db, err = sql.get(env.get(consts.env.DATABASE_RESOURCE))
    if err then return { success = false, error = tostring(err) } end
    local operation, operation_err = containers_repo.stdin_get(db, input.operation_id)
    db:release()
    if operation_err then return { success = false, error = tostring(operation_err) } end
    return { success = true, operation = operation }
end

return { handle = handle }
