local images = require("images")
local test = require("test")

-- Mock docker client recording inspect/pull calls with canned responses.
local function mock_client(opts)
    opts = opts or {}
    local calls = { inspect = {}, pull = {} }
    local client = {}

    function client:inspect_image(name)
        table.insert(calls.inspect, name)
        if opts.present then
            return { Id = "sha256:abc" }, nil
        end
        return nil, "no such image"
    end

    function client:pull_image(from, tag)
        table.insert(calls.pull, { from = from, tag = tag })
        if opts.pull_err then
            return nil, opts.pull_err
        end
        return {}, nil
    end

    return client, calls
end

local function define_tests()
    describe("Docker images.ensure", function()
        it("is a no-op when the image is already present", function()
            local client, calls = mock_client({ present = true })
            local ok, err = images.ensure(client, "mcp/markitdown")
            test.is_true(ok, "ok")
            test.is_nil(err, "no error")
            test.eq(#calls.pull, 0, "no pull when present")
        end)

        it("pulls an untagged image as fromImage with no tag", function()
            local client, calls = mock_client({ present = false })
            local ok, err = images.ensure(client, "mcp/markitdown")
            test.is_true(ok, "ok")
            test.is_nil(err, "no error")
            test.eq(#calls.pull, 1, "pulled once")
            local p = calls.pull[1] :: { from: string, tag: string? }
            test.eq(p.from, "mcp/markitdown", "fromImage is the repo")
            test.is_nil(p.tag, "no tag -> daemon pulls latest")
        end)

        it("splits repo:tag when pulling", function()
            local client, calls = mock_client({ present = false })
            local ok = images.ensure(client, "redis:7")
            test.is_true(ok, "ok")
            local p = calls.pull[1] :: { from: string, tag: string? }
            test.eq(p.from, "redis", "repo split out")
            test.eq(p.tag, "7", "tag split out")
        end)

        it("keeps a registry:port prefix and splits only the trailing tag", function()
            local client, calls = mock_client({ present = false })
            images.ensure(client, "localhost:5000/team/app:1.2")
            local p = calls.pull[1] :: { from: string, tag: string? }
            test.eq(p.from, "localhost:5000/team/app", "registry+repo preserved")
            test.eq(p.tag, "1.2", "trailing tag only")
        end)

        it("surfaces a pull error", function()
            local client = mock_client({ present = false, pull_err = "network down" })
            local ok, err = images.ensure(client, "mcp/markitdown")
            test.is_false(ok, "not ok")
            test.not_nil(err, "error surfaced")
        end)

        it("rejects an empty image", function()
            local client, calls = mock_client({})
            local ok = images.ensure(client, "")
            test.is_false(ok, "not ok")
            test.eq(#calls.inspect, 0, "did not inspect")
        end)
    end)
end

return test.run_cases(define_tests)
