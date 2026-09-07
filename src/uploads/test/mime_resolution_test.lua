local test = require("test")
local upload_lib = require("upload_lib")

local RTF_TYPE = "app:type.rtf_test"
local DOC_TYPE = "app:type.doc_test"

local RTF_BYTES = "{\\rtf1\\ansi\\ansicpg1252 body\\par }"
local OLE2_BYTES = "\208\207\017\224\161\177\026\225 padding"

local function define_tests()
    describe("Client content type resolution", function()
        it("prefers a known extension over a disagreeing claim", function()
            local resolved, claimed = upload_lib.resolve_mime_type(
                "application/msword", "test.rtf"
            )
            test.eq(resolved, "application/rtf")
            test.eq(claimed, "application/msword")
        end)

        it("leaves an agreeing claim alone", function()
            local resolved, claimed = upload_lib.resolve_mime_type("application/msword", "legacy.doc")
            test.eq(resolved, "application/msword")
            test.is_nil(claimed)
        end)

        it("keeps the claim when the extension means nothing to us", function()
            local resolved, claimed = upload_lib.resolve_mime_type("application/rtf", "transcript.e-tran")
            test.eq(resolved, "application/rtf")
            test.is_nil(claimed)
        end)

        it("matches the extension case-insensitively", function()
            test.eq(upload_lib.resolve_mime_type("application/msword", "SHOUTING.RTF"), "application/rtf")
        end)

        it("fills a missing claim from the extension, displacing nothing", function()
            -- A gap is not a wrong answer, so there is no claim to record.
            for _, absent in ipairs({ "", "application/octet-stream" }) do
                local resolved, claimed = upload_lib.resolve_mime_type(absent, "deposition.rtf")
                test.eq(resolved, "application/rtf")
                test.is_nil(claimed)
            end

            local resolved, claimed = upload_lib.resolve_mime_type(nil, "deposition.rtf")
            test.eq(resolved, "application/rtf")
            test.is_nil(claimed)
        end)

        it("falls back to octet-stream when neither side says anything", function()
            test.eq(upload_lib.resolve_mime_type(nil, "noextension"), "application/octet-stream")
            test.eq(upload_lib.resolve_mime_type("", "archive.tar.zzz"), "application/octet-stream")
        end)
    end)

    describe("mime_type_for_extension", function()
        it("answers from the extension alone", function()
            -- The entry point for callers holding an extension and no claim:
            -- connector imports naming a downloaded file. They used to keep
            -- their own copy of this table.
            test.eq(upload_lib.mime_type_for_extension("rtf"), "application/rtf")
            test.eq(upload_lib.mime_type_for_extension("RTF"), "application/rtf")
            test.eq(upload_lib.mime_type_for_extension("msg"), "application/vnd.ms-outlook")
        end)

        it("falls back to octet-stream on anything it does not know", function()
            test.eq(upload_lib.mime_type_for_extension("zzz"), "application/octet-stream")
            test.eq(upload_lib.mime_type_for_extension(""), "application/octet-stream")
            test.eq(upload_lib.mime_type_for_extension(nil), "application/octet-stream")
        end)
    end)

    describe("Upload records carry the resolved type", function()
        it("routes an RTF claimed as a Word document to the RTF type", function()
            local upload, err = upload_lib.upload_file(
                "user-1", RTF_BYTES, "deposition.rtf", #RTF_BYTES, "application/msword"
            )
            test.is_nil(err)
            test.eq(upload.mime_type, "application/rtf")
            test.eq(upload.type_id, RTF_TYPE)
            -- What the client claimed stays on the record.
            test.eq(upload.metadata.client_content_type, "application/msword")
        end)

        it("leaves a genuine Word document on the DOC type", function()
            local upload, err = upload_lib.upload_file(
                "user-1", OLE2_BYTES, "legacy.doc", #OLE2_BYTES, "application/msword"
            )
            test.is_nil(err)
            test.eq(upload.mime_type, "application/msword")
            test.eq(upload.type_id, DOC_TYPE)
            test.is_nil(upload.metadata.client_content_type)
        end)

        it("resolves for server-side callers that pass no type at all", function()
            -- The zip extractor and the connector imports come through here.
            local upload, err = upload_lib.upload_file(
                "user-1", RTF_BYTES, "from_archive.rtf", #RTF_BYTES, nil
            )
            test.is_nil(err)
            test.eq(upload.mime_type, "application/rtf")
            test.eq(upload.type_id, RTF_TYPE)
        end)
    end)
end

return { run = define_tests }
