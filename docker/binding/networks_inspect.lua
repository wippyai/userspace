local docker_client = require("docker_client")

local function handle(input: {id: string})
    if not input.id or input.id == "" then
        return { success = false, error = "id is required" }
    end

    local docker, docker_err = docker_client.new()
    if docker_err then
        return { success = false, error = "docker unavailable: " .. tostring(docker_err) }
    end

    local net, err = docker:inspect_network(input.id)
    if err then
        return { success = false, error = tostring(err) }
    end

    local containers = {}
    if net.Containers and type(net.Containers) == "table" then
        for cid, info in pairs(net.Containers) do
            table.insert(containers, {
                id = cid,
                name = info.Name,
                ipv4 = info.IPv4Address,
                ipv6 = info.IPv6Address,
                mac = info.MacAddress,
            })
        end
    end

    return {
        success = true,
        network = {
            id = net.Id,
            name = net.Name,
            driver = net.Driver,
            scope = net.Scope,
            internal = net.Internal or false,
            attachable = net.Attachable or false,
            ingress = net.Ingress or false,
            containers = containers,
            options = net.Options,
            labels = net.Labels,
        },
    }
end

return { handle = handle }
