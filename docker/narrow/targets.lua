local runtime = require("runtime")
local docker_client = require("docker_client")
local deps = runtime.production(docker_client)
return {
    create = function(v: unknown) return runtime.create_with(v, deps) end,
    find = function(v: unknown) return runtime.find_with(v, deps) end,
    inspect = function(v: unknown) return runtime.inspect_with(v, deps) end,
    start = function(v: unknown) return runtime.start_with(v, deps) end,
    stop = function(v: unknown) return runtime.stop_with(v, deps) end,
    remove = function(v: unknown) return runtime.remove_with(v, deps) end,
}
