local images = {}

-- Ensure an image is present locally, pulling it if missing. Idempotent: a
-- present image is a no-op. Without this, create_container fails for a
-- declarative container whose image was never pulled (e.g. a fresh deploy).
function images.ensure(client, image)
    if not image or image == "" then
        return false, "no image specified"
    end

    local existing, _ = client:inspect_image(image)
    if existing then
        return true, nil
    end

    -- Not present: split "repo:tag" so pull gets fromImage + tag. The tag is the
    -- last colon-segment with no "/" (so "host:5000/repo:7" -> repo "host:5000/repo",
    -- tag "7"; "mcp/markitdown" -> no tag, daemon pulls :latest).
    local from = image
    local tag = nil
    local repo, parsed_tag = image:match("^(.+):([^:/]+)$")
    if repo and parsed_tag then
        from = repo
        tag = parsed_tag
    end

    local _, pull_err = client:pull_image(from, tag)
    if pull_err then
        return false, "pull failed: " .. tostring(pull_err)
    end
    return true, nil
end

return images
