local time = require("time")
local uuid = require("uuid")
local logger = require("logger")
local security = require("security")
local schedule_repo = require("schedule_repo")
local schedule_calculator = require("schedule_calculator")
local contract = require("contract")

-- Constants
local CONST = {
    DEFAULT_POLL_INTERVAL = "5s", -- Default if not provided
    DEFAULT_BATCH_SIZE = 10,      -- Default batch size
    DEFAULT_MAX_CONCURRENT = 20,  -- Default max concurrent tasks
    SCHEDULABLE_CONTRACT = "userspace.scheduler:schedulable"
}

-- Action constants for task completion
local COMPLETION_ACTIONS = {
    RESCHEDULE = "reschedule",
    DISABLE = "disable",
    RETRY = "retry"
}

-- Initialize logger at module level for testability
local log = logger:named("scheduler.worker")

---@class WorkerStats
---@field start_time table Time when worker started
---@field tasks_processed integer Number of tasks processed
---@field tasks_succeeded integer Number of tasks that succeeded
---@field tasks_failed integer Number of tasks that failed
---@field tasks_rescheduled integer Number of tasks rescheduled for next run
---@field tasks_disabled integer Number of tasks disabled
---@field tasks_retried integer Number of tasks reset for retry
---@field batches_processed integer Number of batches processed
---@field avg_batch_size number Average tasks per batch
---@field current_concurrency integer Current running tasks
---@field max_concurrency_reached integer Highest concurrency reached

---@class TaskExecutionResult
---@field task_id string Task identifier
---@field result table|nil Task execution result
---@field error string|nil Error message if task failed
---@field retriable boolean|nil Whether the task should be retried
---@field duration_ms integer Execution duration in milliseconds

---@class WorkerConfig
---@field batch_size integer How many tasks to claim per batch
---@field max_concurrent integer Maximum concurrent tasks allowed
---@field poll_interval string How often to poll for new tasks

---@class WorkerState
---@field currently_running integer Number of tasks currently executing
---@field batch_size integer Configured batch size
---@field max_concurrent integer Maximum allowed concurrent tasks
---@field worker_pid string Worker PID

---@class Dependencies
---@field schedule_repo table Schedule repository for database operations
---@field schedule_calculator table Calculator for next run times
---@field schedulable_contract table Contract for task execution
---@field logger table Logger instance

---Calculate how many tasks can be claimed based on current concurrency
---@param state WorkerState Current worker state
---@return integer claim_limit Number of tasks that can be claimed
local function calculate_claim_limit(state)
    local available_slots = state.max_concurrent - state.currently_running
    if available_slots <= 0 then
        return 0 -- Don't claim anything if at capacity
    end
    return math.min(state.batch_size, available_slots :: number)
end

---Update concurrency tracking when tasks start
---@param state WorkerState Worker state to update
---@param count integer Number of tasks starting
local function on_tasks_started(state, count)
    state.currently_running = state.currently_running + count
end

---Update concurrency tracking when a task completes
---@param state WorkerState Worker state to update
local function on_task_completed(state)
    state.currently_running = math.max(0, state.currently_running - 1)
end

---Execute a single task using the schedulable contract
---@param task table Task data from database
---@param deps Dependencies Injected dependencies
---@return TaskExecutionResult result Task execution result
local function execute_task(task, deps)
    local start_time = time.now():utc() -- Always use UTC
    local task_id = task.id

    deps.logger:debug("Executing task", {
        task_id = task_id,
        implementation = task.task_implementation_id,
        actor_id = task.actor_id,
        actor_scope = task.actor_scope
    })

    -- Apply security context if provided
    local contract_with_context = deps.schedulable_contract

    if task.actor_id and task.actor_scope then
        deps.logger:debug("Applying security context to task", {
            task_id = task_id,
            actor_id = task.actor_id,
            actor_scope = task.actor_scope
        })

        -- Create actor from task data
        local task_actor = security.new_actor(task.actor_id :: string, task.actor_metadata or {})
        if not task_actor then
            return {
                task_id = task_id,
                result = nil,
                error = "Failed to create security actor: " .. task.actor_id,
                retriable = false,
                duration_ms = time.now():utc():sub(start_time):milliseconds()
            }
        end

        -- Get the named scope
        local task_scope, scope_err = security.named_scope(task.actor_scope :: string)
        if scope_err then
            return {
                task_id = task_id,
                result = nil,
                error = "Failed to get security scope '" .. task.actor_scope .. "': " .. scope_err,
                retriable = false,
                duration_ms = time.now():utc():sub(start_time):milliseconds()
            }
        end

        -- Apply security context to contract
        contract_with_context = contract_with_context:with_actor(task_actor):with_scope(task_scope)

        deps.logger:debug("Security context applied successfully", {
            task_id = task_id,
            actor_id = task.actor_id,
            actor_scope = task.actor_scope
        })
    end

    -- Open the implementation with context (and security if provided)
    local instance, err = (contract_with_context :: any):open(task.task_implementation_id :: string, task.task_context)
    if err then
        return {
            task_id = task_id,
            result = nil,
            error = "Failed to open implementation: " .. err,
            retriable = false,
            duration_ms = time.now():utc():sub(start_time):milliseconds()
        }
    end

    -- Build payload for schedulable contract
    local payload = {
        schedule_id = task.id,
        previous_runs = {
            last_run_at = task.last_run_at,
            consecutive_failures = task.consecutive_failures,
            retry_count = task.retry_count,
            last_error = task.last_error
        },
        args = task.task_args
    }

    -- Execute the task
    local result, exec_err = instance:execute(payload)
    local duration = time.now():utc():sub(start_time)

    if exec_err then
        deps.logger:debug("Task execution failed", {
            task_id = task_id,
            implementation = task.task_implementation_id,
            actor_id = task.actor_id,
            error = exec_err,
            duration_ms = duration:milliseconds()
        })
        return {
            task_id = task_id,
            result = nil,
            error = exec_err,
            retriable = true, -- Default to retriable on execution errors
            duration_ms = duration:milliseconds()
        }
    end

    -- Check result format
    if not result or type(result) ~= "table" then
        return {
            task_id = task_id,
            result = nil,
            error = "Invalid result format from implementation",
            retriable = false,
            duration_ms = duration:milliseconds()
        }
    end

    if not result.success then
        local error_msg = result.error or "Task failed without error message"
        local retriable = result.retriable ~= false -- Default to true if not specified

        deps.logger:debug("Task failed", {
            task_id = task_id,
            implementation = task.task_implementation_id,
            actor_id = task.actor_id,
            error = error_msg,
            retriable = retriable,
            duration_ms = duration:milliseconds()
        })
        return {
            task_id = task_id,
            result = result,
            error = error_msg,
            retriable = retriable,
            duration_ms = duration:milliseconds()
        }
    end

    deps.logger:debug("Task succeeded", {
        task_id = task_id,
        implementation = task.task_implementation_id,
        actor_id = task.actor_id,
        duration_ms = duration:milliseconds()
    })

    return {
        task_id = task_id,
        result = result,
        error = nil,
        retriable = nil,
        duration_ms = duration:milliseconds()
    }
end

---Determine what action to take after task completion
---@param task table Task data
---@param exec_result TaskExecutionResult Execution result
---@return string action, string|nil reason
local function determine_completion_action(task, exec_result)
    local is_success = not exec_result.error

    -- The disable/failure reasons carry the implementation's error so operators
    -- see why a schedule stopped, not just a generic flag.
    local failure_detail = tostring(exec_result.error or "no error message")

    -- Once schedules always get disabled after execution (success or failure)
    if task.schedule_type == schedule_repo.SCHEDULE_TYPES.ONCE then
        local reason = is_success and "Once schedule completed successfully"
            or ("Once schedule failed: " .. failure_detail)
        return COMPLETION_ACTIONS.DISABLE, reason
    end

    -- For recurring schedules (interval, ticker, cron)
    if is_success then
        -- Success: reschedule for next run
        return COMPLETION_ACTIONS.RESCHEDULE, nil
    else
        -- Failure: check retry logic
        if not exec_result.retriable then
            return COMPLETION_ACTIONS.DISABLE, "Task failed (non-retriable): " .. failure_detail
        end

        if task.retry_count >= task.max_retries then
            return COMPLETION_ACTIONS.DISABLE,
                "Maximum retries exceeded (" .. task.max_retries .. "): " .. failure_detail
        end

        -- Still have retries left
        return COMPLETION_ACTIONS.RETRY, nil
    end
end

---Handle task completion based on determined action
---@param task table Task data
---@param action string Completion action
---@param reason string|nil Reason for action
---@param deps Dependencies Injected dependencies
---@param stats WorkerStats Statistics to update
---@return boolean success
local function handle_completion_action(task, action, reason, deps, stats)
    local success = false
    local err = nil

    if action == COMPLETION_ACTIONS.RESCHEDULE then
        success, err = deps.schedule_repo.reschedule_task(task.id, deps.schedule_calculator)
        if success then
            stats.tasks_rescheduled = stats.tasks_rescheduled + 1
            deps.logger:debug("Task rescheduled for next run", {
                task_id = task.id,
                schedule_type = task.schedule_type,
                expression = task.schedule_expression,
                actor_id = task.actor_id
            })
        else
            deps.logger:debug("Failed to reschedule task", {
                task_id = task.id,
                actor_id = task.actor_id,
                error = err
            })
        end
    elseif action == COMPLETION_ACTIONS.DISABLE then
        success, err = deps.schedule_repo.disable_schedule(task.id, reason)
        if success then
            stats.tasks_disabled = stats.tasks_disabled + 1
            deps.logger:debug("Task disabled", {
                task_id = task.id,
                actor_id = task.actor_id,
                reason = reason
            })
        else
            deps.logger:debug("Failed to disable task", {
                task_id = task.id,
                actor_id = task.actor_id,
                error = err
            })
        end
    elseif action == COMPLETION_ACTIONS.RETRY then
        success, err = deps.schedule_repo.reset_for_retry(task.id)
        if success then
            stats.tasks_retried = stats.tasks_retried + 1
            deps.logger:debug("Task reset for retry", {
                task_id = task.id,
                actor_id = task.actor_id,
                retry_count = task.retry_count,
                max_retries = task.max_retries
            })
        else
            deps.logger:debug("Failed to reset task for retry", {
                task_id = task.id,
                actor_id = task.actor_id,
                error = err
            })
        end
    else
        deps.logger:debug("Unknown completion action", {
            task_id = task.id,
            actor_id = task.actor_id,
            action = action
        })
    end

    return success
end

---Process a single task from start to completion
---@param task table Task data from database
---@param state WorkerState Worker state
---@param deps Dependencies Injected dependencies
---@param stats WorkerStats Statistics to update
---@return function coroutine_function Function to run in coroutine
local function create_task_processor(task, state, deps, stats)
    return function()
        local task_id = task.id

        -- Mark task as executing
        local mark_ok, mark_err = deps.schedule_repo.mark_executing(task_id)
        if not mark_ok then
            deps.logger:debug("Failed to mark task as executing", {
                task_id = task_id,
                actor_id = task.actor_id,
                error = mark_err
            })
            on_task_completed(state)
            return
        end

        deps.logger:debug("Executing task", {
            task_id = task_id,
            implementation = task.task_implementation_id,
            schedule_type = task.schedule_type,
            actor_id = task.actor_id,
            actor_scope = task.actor_scope,
            retry_count = task.retry_count or 0,
            max_retries = task.max_retries or 3
        })

        -- Execute the task
        local exec_result = execute_task(task, deps)
        local is_success = not exec_result.error

        -- Update execution result counters
        local update_ok, update_err = deps.schedule_repo.update_execution_result(task_id, is_success, exec_result.error)
        if not update_ok then
            deps.logger:debug("Failed to update execution result", {
                task_id = task_id,
                actor_id = task.actor_id,
                error = update_err
            })
        end

        -- Update stats
        if is_success then
            stats.tasks_succeeded = stats.tasks_succeeded + 1
            deps.logger:debug("Task completed successfully", {
                task_id = task_id,
                implementation = task.task_implementation_id,
                schedule_type = task.schedule_type,
                actor_id = task.actor_id,
                duration_ms = exec_result.duration_ms
            })
        else
            stats.tasks_failed = stats.tasks_failed + 1
            deps.logger:debug("Task failed", {
                task_id = task_id,
                implementation = task.task_implementation_id,
                schedule_type = task.schedule_type,
                actor_id = task.actor_id,
                error = exec_result.error,
                retriable = exec_result.retriable,
                retry_count = task.retry_count or 0,
                max_retries = task.max_retries or 3,
                duration_ms = exec_result.duration_ms
            })
        end

        -- Determine and handle completion action
        local action, reason = determine_completion_action(task, exec_result)
        local action_success = handle_completion_action(task, action, reason, deps, stats)

        if action_success then
            stats.tasks_processed = stats.tasks_processed + 1
            deps.logger:debug("Task processing completed", {
                task_id = task_id,
                actor_id = task.actor_id,
                action = action,
                total_processed = stats.tasks_processed
            })
        else
            deps.logger:debug("Failed to complete task processing", {
                task_id = task_id,
                actor_id = task.actor_id,
                action = action,
                reason = reason
            })
        end

        -- Always update concurrency tracking when task completes
        on_task_completed(state)

        -- Update current concurrency stat
        stats.current_concurrency = state.currently_running
    end
end

---Process a batch of tasks in parallel using coroutines
---@param tasks table[] Array of task data
---@param state WorkerState Worker state
---@param deps Dependencies Injected dependencies
---@param stats WorkerStats Statistics to update
local function process_batch_parallel(tasks, state, deps, stats)
    if not tasks or #tasks == 0 then
        return
    end

    local batch_size = #tasks
    stats.batches_processed = stats.batches_processed + 1
    stats.avg_batch_size = ((stats.avg_batch_size * (stats.batches_processed - 1)) + batch_size) /
        stats.batches_processed

    deps.logger:debug("Processing task batch", {
        batch_size = batch_size,
        worker_pid = state.worker_pid,
        current_concurrency = state.currently_running,
        max_concurrent = state.max_concurrent
    })

    -- Update concurrency tracking
    on_tasks_started(state, batch_size)
    stats.current_concurrency = state.currently_running
    stats.max_concurrency_reached = math.max(stats.max_concurrency_reached, state.currently_running)

    -- Spawn coroutines for parallel execution
    for _, task in ipairs(tasks) do
        coroutine.spawn(create_task_processor(task, state, deps, stats))
    end
end

---Poll for work and process any available tasks
---@param state WorkerState Worker state
---@param deps Dependencies Injected dependencies
---@param stats WorkerStats Statistics to update
local function do_work(state, deps, stats)
    -- Calculate how many tasks we can claim
    local claim_limit = calculate_claim_limit(state)

    if claim_limit <= 0 then
        deps.logger:debug("Skipping task claim - at max concurrency", {
            currently_running = state.currently_running,
            max_concurrent = state.max_concurrent
        })
        return
    end

    -- Claim tasks from repository
    local tasks, err = deps.schedule_repo.claim_ready_tasks(state.worker_pid, claim_limit)
    if err then
        deps.logger:debug("Failed to claim tasks", { error = err })
        return
    end

    -- Process the batch in parallel
    process_batch_parallel(tasks, state, deps, stats)
end

---Initialize dependencies with optional overrides for testing
---@param worker_pid string Worker PID
---@param overrides table|nil Dependency overrides for testing
---@return Dependencies deps Initialized dependencies
local function initialize_dependencies(worker_pid, overrides)
    overrides = overrides or {}

    local deps = {
        schedule_repo = overrides.schedule_repo or schedule_repo,
        schedule_calculator = overrides.schedule_calculator or schedule_calculator,
        schedulable_contract = nil, -- Will be initialized below
        logger = overrides.logger or log:with({ worker_pid = worker_pid })
    }

    -- Get schedulable contract
    if overrides.schedulable_contract then
        deps.schedulable_contract = overrides.schedulable_contract
    else
        local contract_instance, contract_err = contract.get(CONST.SCHEDULABLE_CONTRACT)
        if contract_err then
            error("Failed to get schedulable contract: " .. contract_err)
        end
        deps.schedulable_contract = contract_instance
    end

    return deps
end

---Entry point for the scheduler worker with parallel batch processing
---@param config WorkerConfig|nil Worker configuration (passed from root)
---@param dependency_overrides table|nil Dependency overrides for testing
---@return table Worker result with stats
local function run(config, dependency_overrides)
    -- Handle config parameter (this is what root actually passes)
    config = config or {}

    local batch_size = config.batch_size or CONST.DEFAULT_BATCH_SIZE
    local max_concurrent = config.max_concurrent or CONST.DEFAULT_MAX_CONCURRENT
    local poll_interval = config.poll_interval or CONST.DEFAULT_POLL_INTERVAL

    -- Use PID as worker identifier
    local worker_pid = process.pid()

    -- Initialize dependencies
    local deps = initialize_dependencies(worker_pid, dependency_overrides)

    deps.logger:debug("Worker starting with parallel batch processing", {
        worker_pid = worker_pid,
        batch_size = batch_size,
        max_concurrent = max_concurrent,
        poll_interval = poll_interval
    })

    -- Worker state for concurrency control
    local state = {
        currently_running = 0,
        batch_size = batch_size,
        max_concurrent = max_concurrent,
        worker_pid = worker_pid
    }

    ---@type WorkerStats
    local stats = {
        start_time = time.now():utc(), -- Always use UTC
        tasks_processed = 0,
        tasks_succeeded = 0,
        tasks_failed = 0,
        tasks_rescheduled = 0,
        tasks_disabled = 0,
        tasks_retried = 0,
        batches_processed = 0,
        avg_batch_size = 0,
        current_concurrency = 0,
        max_concurrency_reached = 0
    }

    local work_timer = time.ticker(poll_interval)
    local events = process.events()
    local running = true

    -- Main worker loop
    while running do
        local result = channel.select({
            work_timer:channel():case_receive(),
            events:case_receive()
        })

        if result.channel == work_timer:channel() then
            if running then
                do_work(state, deps, stats)
            end
        elseif result.channel == events then
            local event = result.value
            if event.kind == process.event.CANCEL then
                deps.logger:debug("Worker received cancel signal")
                running = false
            end
        end
    end

    work_timer:stop()

    local uptime = time.now():utc():sub(stats.start_time):seconds() -- Always use UTC
    local success_rate = stats.tasks_processed > 0 and (stats.tasks_succeeded / stats.tasks_processed * 100) or 0

    deps.logger:info("Worker completed", {
        tasks_processed = stats.tasks_processed,
        tasks_succeeded = stats.tasks_succeeded,
        success_rate = success_rate
    })

    return {
        worker_pid = worker_pid,
        stats = stats
    }
end

-- Export functions for testing
return {
    run = run,

    -- Export internal functions for unit testing
    calculate_claim_limit = calculate_claim_limit,
    on_tasks_started = on_tasks_started,
    on_task_completed = on_task_completed,
    execute_task = execute_task,
    determine_completion_action = determine_completion_action,
    handle_completion_action = handle_completion_action,
    initialize_dependencies = initialize_dependencies,
    CONST = CONST,
    COMPLETION_ACTIONS = COMPLETION_ACTIONS
}