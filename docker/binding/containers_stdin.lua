local json = require("json")
local sql = require("sql")
local env = require("env")
local uuid = require("uuid")
local consts = require("consts")
local containers_repo = require("containers_repo")

local function get_db()
    return sql.get(env.get(consts.env.DATABASE_RESOURCE))
end

-- `success` means that the request was durably accepted, never that bytes were
-- delivered. Delivery is represented by the persisted operation state and an
-- optional callback message on `stdin.result`.
local function handle(input: {
    container_id: string, data: string, operation_id: string?, idempotency_key: string?,
    request_digest: string?, reply_to: string?, reply_topic: string?,
})
    if not input.container_id or input.container_id == "" then
        return { success = false, error = "container_id is required" }
    end

    if type(input.data) ~= "string" then
        return { success = false, error = "data is required" }
    end
    if #input.data > 1048576 then return { success = false, error = "data exceeds 1048576 bytes" } end

    local operation_id = input.operation_id or input.idempotency_key or uuid.v4()
    local request_digest = input.request_digest or ("legacy:" .. operation_id)
    if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 256 then
        return { success = false, error = "operation_id is invalid" }
    end
    if type(request_digest) ~= "string" or request_digest == "" or #request_digest > 512 then
        return { success = false, error = "request_digest is invalid" }
    end

    local db, db_err = get_db()
    if db_err then return { success = false, state = "uncertain", error = tostring(db_err) } end
    local container, container_err = containers_repo.get(db, input.container_id)
    if container_err or not container then
        db:release()
        return { success = false, state = "failed", error = container_err or "container not found" }
    end
    local operation, operation_err = containers_repo.stdin_begin(db, input.container_id,
        operation_id, request_digest, #input.data)
    if operation_err then
        db:release()
        return { success = false, state = "failed", error = tostring(operation_err) }
    end

    -- A Docker-managed container has no attach/write acknowledgement in this
    -- package. It is explicitly unsupported instead of silently dropping input.
    local config = type(container.config) == "table" and container.config or {}
    if operation.state == "accepted" and config.interactive ~= true then
        containers_repo.stdin_settle(db, operation_id, "unsupported", "userspace.docker",
            "managed Docker stdin acknowledgement is unsupported")
        operation = containers_repo.stdin_get(db, operation_id)
        db:release()
        return { success = false, state = "unsupported", operation = operation,
            error = "managed Docker stdin acknowledgement is unsupported" }
    end
    db:release()

    -- A dispatched operation is never sent again: loss after dispatch is
    -- ambiguous and must reconcile through status, not duplicate stdin bytes.
    if operation.state ~= "accepted" then
        return { success = operation.state == "delivered" or operation.state == "dispatched",
            state = operation.state,
            operation = operation, delivery_confirmed = operation.state == "delivered" }
    end

    local root_pid = process.registry.lookup(consts.registry.ROOT)
    if not root_pid then
        local retry_db = get_db()
        if retry_db then
            containers_repo.stdin_settle(retry_db, operation_id, "uncertain", "userspace.docker",
                "docker service not available")
            operation = containers_repo.stdin_get(retry_db, operation_id) or operation
            retry_db:release()
        end
        return { success = false, state = "uncertain", operation = operation,
            error = "docker service not available" }
    end

    local dispatch_db, dispatch_db_err = get_db()
    if dispatch_db_err then
        return { success = false, state = "uncertain", operation = operation,
            error = tostring(dispatch_db_err) }
    end
    local dispatched, dispatch_err = containers_repo.stdin_dispatch(dispatch_db, operation_id)
    dispatch_db:release()
    if not dispatched then
        return { success = false, state = "uncertain", operation = operation,
            error = tostring(dispatch_err) }
    end

    process.send(root_pid, consts.topic.STDIN, json.encode({
        container_id = input.container_id,
        data = input.data,
        operation_id = operation_id,
        reply_to = input.reply_to,
        reply_topic = input.reply_topic,
    }))

    return { success = true, state = "dispatched", operation = dispatched,
        delivery_confirmed = false }
end

return { handle = handle }
