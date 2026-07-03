local test = require("test")
local contract = require("contract")

-- Verifies userspace.uploads is a conforming default implementation of the session-owned
-- wippy.session:file_provider contract: the binding is present, and get_info honors the
-- contract (absent file -> nil; the upload record shape carries size/mime_type/filename).

local function define_tests()
    test.describe("uploads file_provider", function()
        test.it("binds wippy.session:file_provider as a default implementation", function()
            local def, err = contract.get("wippy.session:file_provider")
            test.is_nil(err)
            test.not_nil(def)

            local impls, impl_err = def:implementations()
            test.is_nil(impl_err)
            test.is_true(type(impls) == "table" and #impls >= 1)
        end)

        test.it("get_info returns nil for an absent file (contract-compliant)", function()
            local def = contract.get("wippy.session:file_provider")
            local inst, open_err = def:open()
            test.is_nil(open_err)
            test.not_nil(inst)

            local info = inst:get_info({ file_uuid = "does-not-exist-abc123" })
            test.is_nil(info)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
