local sql = require("sql")
local security = require("security")
local contract = require("contract")
local ops = require("ops")
local component_reader = require("component_reader")
local json = require("json")

-- Constants
local DELETABLE_CONTRACT = "userspace.contract:deletable"

local VALIDATION_ERRORS = {
    INVALID_REQUEST = "Invalid request: must be a table",
    MISSING_COMPONENT_ID = "component_id is required and must be a non-empty string",
    NO_ACTOR = "No authenticated actor found",
    INVALID_ACTOR = "Invalid actor ID"
}

local DATABASE_ERRORS = {
    CONNECTION_FAILED = "Failed to connect to database",
    TRANSACTION_FAILED = "Failed to begin transaction",
    ACCESS_DENIED = "Component not found or insufficient access to delete",
    DELETE_FAILED = "Failed to delete component",
    COMMIT_FAILED = "Failed to commit transaction"
}

local function handle(request_dto)
    if not request_dto or type(request_dto) ~= "table" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_REQUEST }
    end

    if not request_dto.component_id or type(request_dto.component_id) ~= "string" or request_dto.component_id == "" then
        return { success = false, error = VALIDATION_ERRORS.MISSING_COMPONENT_ID }
    end

    local actor = security.actor()
    if not actor then
        return { success = false, error = VALIDATION_ERRORS.NO_ACTOR }
    end

    local user_id = actor:id()
    if not user_id or user_id == "" then
        return { success = false, error = VALIDATION_ERRORS.INVALID_ACTOR }
    end

    -- Check access and read component info before opening a transaction.
    local reader = component_reader.new()
        :with_user(user_id)
        :with_components(request_dto.component_id)
        :with_access_mask(ops.ACCESS.DELETE)
        :include_options({
            meta = false,
            private_context = true
        })

    local component, read_err = reader:one()
    if read_err then
        return { success = false, error = tostring(read_err) }
    end
    if not component then
        return { success = false, error = DATABASE_ERRORS.ACCESS_DENIED }
    end

    -- Try delegated deletion if the component implements the deletable contract.
    if component.impl_id then
        local deletable_contract, contract_err = contract.get(DELETABLE_CONTRACT)
        if deletable_contract then
            local ctx = {}
            if type(component.private_context) == "table" then
                for k, v in pairs(component.private_context) do
                    ctx[k] = v
                end
            end
            ctx.component_id = request_dto.component_id

            local instance, open_err = deletable_contract:open(component.impl_id :: string, ctx)
            if instance then
                local cleanup_result, cleanup_err = instance:delete({})
                local cleanup_success = (not cleanup_err and cleanup_result and cleanup_result.success)

                -- Service unregisters regardless of cleanup result to avoid orphans.
                local db, err_db = sql.get(ops.DB_RESOURCE)
                if err_db then
                    return {
                        success = false,
                        error = "Cleanup " .. (cleanup_success and "succeeded" or "failed") ..
                            " but failed to connect to database: " .. err_db
                    }
                end

                local tx, err_tx = db:begin()
                if err_tx then
                    db:release()
                    return {
                        success = false,
                        error = "Cleanup " .. (cleanup_success and "succeeded" or "failed") ..
                            " but failed to begin transaction: " .. err_tx
                    }
                end

                local has_access = ops.check_user_access(tx, user_id, request_dto.component_id, ops.ACCESS.DELETE)
                if not has_access then
                    tx:rollback()
                    db:release()
                    return { success = false, error = DATABASE_ERRORS.ACCESS_DENIED }
                end

                local delete_command = {
                    type = ops.COMMAND_TYPES.DELETE_COMPONENT,
                    payload = { component_id = request_dto.component_id }
                }

                local delete_result, err_delete = ops.dispatch(tx, db, delete_command)
                if err_delete then
                    tx:rollback()
                    db:release()
                    return {
                        success = false,
                        error = "Cleanup " .. (cleanup_success and "succeeded" or "failed") ..
                            " but failed to unregister: " .. tostring(err_delete)
                    }
                end

                local commit_ok, err_commit = tx:commit()
                if err_commit then
                    tx:rollback()
                    db:release()
                    return {
                        success = false,
                        error = "Cleanup " .. (cleanup_success and "succeeded" or "failed") ..
                            " but failed to commit: " .. err_commit
                    }
                end

                db:release()

                if cleanup_success then
                    return {
                        component_id = request_dto.component_id,
                        deleted = delete_result.changes_made or false,
                        success = true
                    }
                else
                    return {
                        component_id = request_dto.component_id,
                        deleted = delete_result.changes_made or false,
                        success = false,
                        error = "Component cleanup failed but component was unregistered: " ..
                            (cleanup_err or "unknown error")
                    }
                end
            end
            -- Cannot open deletable contract: component is not deletable.
        end
    end

    -- Component is NOT deletable: normal deletion.
    local db, err_db = sql.get(ops.DB_RESOURCE)
    if err_db then
        return { success = false, error = DATABASE_ERRORS.CONNECTION_FAILED .. ": " .. err_db }
    end

    local tx, err_tx = db:begin()
    if err_tx then
        db:release()
        return { success = false, error = DATABASE_ERRORS.TRANSACTION_FAILED .. ": " .. err_tx }
    end

    local has_access = ops.check_user_access(tx, user_id, request_dto.component_id, ops.ACCESS.DELETE)
    if not has_access then
        tx:rollback()
        db:release()
        return { success = false, error = DATABASE_ERRORS.ACCESS_DENIED }
    end

    local delete_command = {
        type = ops.COMMAND_TYPES.DELETE_COMPONENT,
        payload = { component_id = request_dto.component_id }
    }

    local delete_result, err_delete = ops.dispatch(tx, db, delete_command)
    if err_delete then
        tx:rollback()
        db:release()
        return { success = false, error = DATABASE_ERRORS.DELETE_FAILED .. ": " .. tostring(err_delete) }
    end

    local commit_ok, err_commit = tx:commit()
    if err_commit then
        tx:rollback()
        db:release()
        return { success = false, error = DATABASE_ERRORS.COMMIT_FAILED .. ": " .. err_commit }
    end

    db:release()

    return {
        component_id = request_dto.component_id,
        deleted = delete_result.changes_made or false,
        success = true
    }
end

return { handle = handle }
