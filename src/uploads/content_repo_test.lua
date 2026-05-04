local content_repo = require("content_repo")
local test = require("test")

local function define_tests()
    describe("content metadata merging", function()
        it("merges new keys without dropping existing metadata", function()
            local merged, err = content_repo._test.merge_metadata_json('{"owner":"u1","keep":true}', {
                owner = "u2",
                added = "yes",
            })

            test.is_nil(err)
            if merged == nil then
                error("expected merged metadata")
            end
            test.eq(merged.owner, "u2")
            test.eq(merged.keep, true)
            test.eq(merged.added, "yes")
        end)

        it("treats empty current metadata as an empty object", function()
            local merged, err = content_repo._test.merge_metadata_json("", {
                added = "yes",
            })

            test.is_nil(err)
            if merged == nil then
                error("expected merged metadata")
            end
            test.eq(merged.added, "yes")
        end)

        it("returns a clear error for corrupt existing metadata", function()
            local merged, err = content_repo._test.merge_metadata_json("{bad json", {
                added = "yes",
            })

            test.is_nil(merged)
            test.contains(err, "Failed to decode current metadata")
        end)
    end)
end

return { run_tests = test.run_cases(define_tests) }
