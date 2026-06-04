local reclaim = require("reclaim")
local test = require("test")

-- Records list/remove calls and replays canned responses so reclaim_existing can
-- be exercised without a live Docker daemon.
local function mock_client(opts)
    opts = opts or {}
    local calls = { list = {}, remove = {} }
    local client = {}

    function client:list_containers(filters)
        table.insert(calls.list, filters)
        if opts.list_err then
            return nil, opts.list_err
        end
        return opts.containers or {}, nil
    end

    function client:remove_container(id, force)
        table.insert(calls.remove, { id = id, force = force })
        if opts.remove_err then
            return nil, opts.remove_err
        end
        return true, nil
    end

    return client, calls
end

local function define_tests()
    describe("Docker reclaim_existing", function()
        it("force-removes a container whose name matches exactly", function()
            local client, calls = mock_client({
                containers = { { Id = "abc123", Names = { "/markitdown" } } },
            })
            local removed, err = reclaim.reclaim_existing(client, "markitdown")
            test.is_nil(err, "no error")
            test.eq(removed, 1, "one container removed")
            test.eq(#calls.remove, 1, "remove called once")
            local removal = calls.remove[1] :: { id: string, force: boolean }
            test.eq(removal.id, "abc123", "removed the matching id")
            test.is_true(removal.force, "removed with force")
        end)

        it("ignores a substring match that is not the exact name", function()
            local client, calls = mock_client({
                containers = { { Id = "abc123", Names = { "/markitdown-sidecar" } } },
            })
            local removed, err = reclaim.reclaim_existing(client, "markitdown")
            test.is_nil(err, "no error")
            test.eq(removed, 0, "nothing removed")
            test.eq(#calls.remove, 0, "remove never called")
        end)

        it("removes every exact match and leaves unrelated containers", function()
            local client, calls = mock_client({
                containers = {
                    { Id = "a", Names = { "/markitdown" } },
                    { Id = "b", Names = { "/other" } },
                    { Id = "c", Names = { "/markitdown" } },
                },
            })
            local removed, err = reclaim.reclaim_existing(client, "markitdown")
            test.is_nil(err, "no error")
            test.eq(removed, 2, "two matching containers removed")
            test.eq(#calls.remove, 2, "remove called twice")
        end)

        it("removes nothing when no container exists", function()
            local client, calls = mock_client({ containers = {} })
            local removed, err = reclaim.reclaim_existing(client, "markitdown")
            test.is_nil(err, "no error")
            test.eq(removed, 0, "nothing removed")
            test.eq(#calls.remove, 0, "remove never called")
        end)

        it("does nothing and never lists for an empty name", function()
            local client, calls = mock_client({})
            local removed, err = reclaim.reclaim_existing(client, "")
            test.is_nil(err, "no error")
            test.eq(removed, 0, "nothing removed")
            test.eq(#calls.list, 0, "list never called")
        end)

        it("does nothing and never lists for a nil name", function()
            local client, calls = mock_client({})
            local removed, err = reclaim.reclaim_existing(client, nil)
            test.is_nil(err, "no error")
            test.eq(removed, 0, "nothing removed")
            test.eq(#calls.list, 0, "list never called")
        end)

        it("surfaces a list error without removing", function()
            local client, calls = mock_client({ list_err = "daemon unreachable" })
            local removed, err = reclaim.reclaim_existing(client, "markitdown")
            test.not_nil(err, "error surfaced")
            test.eq(removed, 0, "nothing removed")
            test.eq(#calls.remove, 0, "remove never called")
        end)

        it("surfaces a remove error and stops", function()
            local client = mock_client({
                containers = {
                    { Id = "a", Names = { "/markitdown" } },
                    { Id = "b", Names = { "/markitdown" } },
                },
                remove_err = "permission denied",
            })
            local removed, err = reclaim.reclaim_existing(client, "markitdown")
            test.not_nil(err, "error surfaced")
            test.eq(removed, 0, "stops on the first remove error")
        end)
    end)
end

return test.run_cases(define_tests)
