local docker_client = require("docker_client")
local sql = require("sql")
local env = require("env")
local containers_repo = require("containers_repo")

local consts = require("consts")
local function get_db()
    local db_id = env.get(consts.env.DATABASE_RESOURCE)
    return sql.get(db_id)
end

local function handle(input: {id: string})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end

    local db, db_err = get_db()
    if db_err then
        return { success = false, error = tostring(db_err) }
    end

    local container = containers_repo.get(db, input.id)
    if not container or not container.docker_id or container.docker_id == "" then
        db:release()
        return { success = false, error = "container not found or no docker_id" }
    end
    db:release()

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local stats, err = docker:container_stats(tostring(container.docker_id))
    if err then
        return { success = false, error = tostring(err) }
    end

    local cpu_percent = 0
    if stats.cpu_stats and stats.precpu_stats then
        local cpu_delta = (stats.cpu_stats.cpu_usage and stats.cpu_stats.cpu_usage.total_usage or 0) -
            (stats.precpu_stats.cpu_usage and stats.precpu_stats.cpu_usage.total_usage or 0)
        local sys_delta = (stats.cpu_stats.system_cpu_usage or 0) - (stats.precpu_stats.system_cpu_usage or 0)
        local num_cpus = stats.cpu_stats.online_cpus or 1
        if sys_delta > 0 and cpu_delta > 0 then
            cpu_percent = (cpu_delta / sys_delta) * num_cpus * 100
        end
    end

    local mem_usage = 0
    local mem_limit = 0
    local mem_percent = 0
    if stats.memory_stats then
        mem_usage = tonumber(stats.memory_stats.usage) or 0
        mem_limit = tonumber(stats.memory_stats.limit) or 0
        if mem_limit > 0 then
            mem_percent = (mem_usage / mem_limit) * 100
        end
    end

    local net_rx = 0
    local net_tx = 0
    if stats.networks then
        for _, iface in pairs(stats.networks) do
            net_rx = net_rx + (iface.rx_bytes or 0)
            net_tx = net_tx + (iface.tx_bytes or 0)
        end
    end

    local blk_read = 0
    local blk_write = 0
    if stats.blkio_stats and stats.blkio_stats.io_service_bytes_recursive then
        for _, entry in ipairs(stats.blkio_stats.io_service_bytes_recursive) do
            if entry.op == "read" or entry.op == "Read" then
                blk_read = blk_read + (entry.value or 0)
            elseif entry.op == "write" or entry.op == "Write" then
                blk_write = blk_write + (entry.value or 0)
            end
        end
    end

    return {
        success = true,
        stats = {
            cpu_percent = cpu_percent,
            memory_usage = mem_usage,
            memory_limit = mem_limit,
            memory_percent = mem_percent,
            network_rx = net_rx,
            network_tx = net_tx,
            block_read = blk_read,
            block_write = blk_write,
            pids = stats.pids_stats and stats.pids_stats.current or 0,
        },
    }
end

return { handle = handle }
