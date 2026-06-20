local test = require("test")
local registry = require("registry")
local process_worker = require("process_worker")

local function value(entry: any, key: string): any
    if type(entry) ~= "table" then return nil end
    if entry[key] ~= nil then return entry[key] end
    if type(entry.data) == "table" then return entry.data[key] end
    return nil
end

local function define_tests()
    describe("Upload Processing Worker", function()
        it("runs the live queue consumer under the process security group", function()
            local entry, err = registry.get("userspace.uploads:process_consumer")
            test.is_nil(err)
            test.not_nil(entry)

            local groups = (((value(entry, "lifecycle") or {}).security or {}).groups or {})
            local has_process_group = false
            for _, group in ipairs(groups) do
                if group == "wippy.security:process" then
                    has_process_group = true
                    break
                end
            end

            test.eq(has_process_group, true, "process_consumer must inherit process grants for db-backed upload processing")
        end)

        it("does not acknowledge repository failures as skipped uploads", function()
            mock("upload_repo.get", function()
                return nil, "Failed to connect to database: denied"
            end)

            local result, err = process_worker.handler('{"upload_id":"upload-1"}')
            test.is_nil(result)
            test.not_nil(err)
            test.contains(tostring(err), "failed to load upload")
        end)

        it("keeps missing uploads idempotent", function()
            mock("upload_repo.get", function()
                return nil, "Upload not found"
            end)

            local result, err = process_worker.handler('{"upload_id":"missing"}')
            test.is_nil(err)
            test.eq(result.skipped, true)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)

local function run(options: any): any
    return run_cases(options)
end

return { run = run }
