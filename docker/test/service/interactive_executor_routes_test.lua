local test = require("test")
local routes = require("routes")

local function registry_fixture(entries)
    return {
        find = function(criteria)
            local found = {}
            for _, entry in pairs(entries) do
                if entry.meta and entry.meta.type == criteria["meta.type"] then table.insert(found, entry) end
            end
            return found, nil
        end,
        get = function(id) return entries[id], nil end,
    }
end

local function define_tests()
    describe("Interactive Docker executor routes", function()
        it("loads and revalidates an exact exec.docker image route", function()
            local registry_api = registry_fixture({
                ["app:route"] = { id = "app:route", kind = "registry.entry",
                    meta = { type = "docker.interactive_executor" },
                    data = { image = "agent@sha256:abc", executor = "app:agent_exec" } },
                ["app:agent_exec"] = { id = "app:agent_exec", kind = "exec.docker",
                    data = { image = "agent@sha256:abc" } },
            })
            local loaded, load_err = routes.load(registry_api)
            test.is_nil(load_err)
            local route, resolve_err = routes.resolve(loaded, "agent@sha256:abc", registry_api)
            test.is_nil(resolve_err)
            test.eq(route.executor_id, "app:agent_exec")
        end)

        it("fails closed for missing, non-Docker, mismatched, duplicate, and replaced routes", function()
            local entries = {
                ["app:route"] = { id = "app:route", kind = "registry.entry",
                    meta = { type = "docker.interactive_executor" },
                    data = { image = "agent:one", executor = "app:exec" } },
                ["app:exec"] = { id = "app:exec", kind = "exec.docker", data = { image = "agent:one" } },
            }
            local registry_api = registry_fixture(entries)
            local loaded = routes.load(registry_api)
            local missing = routes.resolve(loaded, "agent:two", registry_api)
            test.is_nil(missing)
            entries["app:exec"].kind = "exec.native"
            local wrong_kind = routes.resolve(loaded, "agent:one", registry_api)
            test.is_nil(wrong_kind)
            entries["app:exec"].kind = "exec.docker"
            entries["app:exec"].data.image = "agent:two"
            local wrong_image = routes.resolve(loaded, "agent:one", registry_api)
            test.is_nil(wrong_image)
            entries["app:exec"].data.image = "agent:one"
            entries["app:route"].data.executor = "app:replacement"
            local replaced = routes.resolve(loaded, "agent:one", registry_api)
            test.is_nil(replaced)

            entries["app:route"].data.executor = "app:exec"
            entries["app:duplicate"] = { id = "app:duplicate", kind = "registry.entry",
                meta = { type = "docker.interactive_executor" },
                data = { image = "agent:one", executor = "app:exec" } }
            local duplicated = routes.load(registry_api)
            test.is_nil(duplicated)
        end)
    end)
end

return test.run_cases(define_tests)
