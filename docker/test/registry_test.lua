local test = require("test")
local events = require("events")
local time = require("time")

local function define_tests()
    describe("Registry Event Subscription", function()

        it("subscribes to registry entry.create events", function()
            local sub, err = events.subscribe("registry", "entry.create")
            test.is_nil(err, "subscribe succeeds")
            test.not_nil(sub, "subscription returned")

            local ch = sub:channel()
            test.not_nil(ch, "channel returned")

            sub:close()
        end)

        it("receives events on the subscription channel", function()
            local sub, err = events.subscribe("registry")
            test.is_nil(err, "subscribe succeeds")

            local ch = sub:channel()
            test.not_nil(ch, "channel returned")

            -- send a synthetic registry event
            events.send("registry", "entry.create", "test.docker:reactive_container", {
                id = "test.docker:reactive_container",
                kind = "registry.entry",
                meta = { type = "docker.container" },
                data = {
                    image = "alpine:latest",
                    command = "echo reactive",
                },
            })

            local timer = time.after("2s")
            local result = channel.select({
                ch:case_receive(),
                timer:case_receive(),
            })

            if result.channel == ch then
                local evt = result.value
                test.not_nil(evt, "event received")
                test.eq(evt.kind, "entry.create", "event kind is entry.create")
                test.eq(evt.path, "test.docker:reactive_container", "event path matches")
                test.not_nil(evt.data, "event data present")
            else
                test.fail("timed out waiting for registry event")
            end

            sub:close()
        end)

        it("filters events by kind", function()
            local sub, err = events.subscribe("registry", "entry.delete")
            test.is_nil(err, "subscribe succeeds")

            local ch = sub:channel()

            -- send a create event, which the delete subscription should not receive
            events.send("registry", "entry.create", "test.docker:filtered_out", {
                id = "test.docker:filtered_out",
                kind = "registry.entry",
                meta = { type = "docker.container" },
                data = { image = "alpine:latest", command = "echo nope" },
            })

            local timer = time.after("500ms")
            local result = channel.select({
                ch:case_receive(),
                timer:case_receive(),
            })

            -- should timeout since we subscribed to delete but sent create
            test.ok(result.channel ~= ch, "no event received for filtered kind")

            sub:close()
        end)

        it("matches docker.container meta type in event data", function()
            local sub, err = events.subscribe("registry", "entry.create")
            test.is_nil(err, "subscribe succeeds")

            local ch = sub:channel()

            -- send an event with docker.container type
            events.send("registry", "entry.create", "test.docker:typed_entry", {
                id = "test.docker:typed_entry",
                kind = "registry.entry",
                meta = { type = "docker.container" },
                data = {
                    image = "nginx:latest",
                    command = "nginx -g 'daemon off;'",
                    ports = { { host = 9999, container = 80 } },
                    network = "test-net",
                },
            })

            local timer = time.after("2s")
            local result = channel.select({
                ch:case_receive(),
                timer:case_receive(),
            })

            test.ok(result.channel == ch, "event received")
            local evt = result.value
            test.eq(evt.data.meta.type, "docker.container", "meta type is docker.container")
            test.eq(evt.data.data.image, "nginx:latest", "image field present")
            test.not_nil(evt.data.data.ports, "ports field present")
            test.eq(evt.data.data.network, "test-net", "network field present")

            sub:close()
        end)
    end)
end

return test.run_cases(define_tests)
