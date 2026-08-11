# userspace/uploads

File upload handling with content processing and resource management for Wippy applications.

## Features

- File upload processing pipeline
- Content extraction and storage
- Resource registry integration
- Upload type detection and validation
- Migrations for upload tables

## Installation

```yaml
# In your deps/_index.yaml
- name: dependency.uploads
  kind: ns.dependency
  component: userspace/uploads
  version: ">=0.4.0"
```

## Usage

### Upload Library

```lua
local upload_lib = require("userspace.uploads:upload_lib")

-- Process file upload
local upload_id, err = upload_lib.process_upload(file_data, {
    filename = "document.pdf",
    content_type = "application/pdf"
})

-- Get upload info
local info = upload_lib.get_info(upload_id)
```

### Content Repository

```lua
local content_repo = require("userspace.uploads:content_repo")

-- Store extracted content
content_repo.store(upload_id, content, content_type)

-- Retrieve content
local content = content_repo.get(upload_id)
```

### Upload Repository

```lua
local upload_repo = require("userspace.uploads:upload_repo")

-- Create upload record
local id = upload_repo.create({
    filename = "file.pdf",
    size = 1024,
    content_type = "application/pdf"
})

-- List uploads
local uploads = upload_repo.list(options)
```

### Processing Pipeline

```lua
local pipeline = require("userspace.uploads:pipeline")

-- Run content extraction pipeline
pipeline.run(upload_id)
```

### Multipart Uploads

For files larger than a single presigned PUT allows (5 GiB on S3), the module
exposes a presigned multipart flow. Requires a cloud storage provider with the
multipart capability (S3); other providers reject the calls.

HTTP endpoints (mounted on the configured router):

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/uploads/multipart` | Start: `{filename, size, content_type?, metadata?, upload_token?}` → `{upload_id, object_key, part_size, min_part_size, max_parts}` |
| POST | `/uploads/multipart/parts` | Presign part URLs: `{upload_id, parts: [1,2,...] \| from/to, expires_in?}` → `{urls: [{part_number, url}]}` (≤ 1000 per call) |
| POST | `/uploads/multipart/complete` | Assemble: `{upload_id, parts: [{part_number, etag}], upload_token?}` → same shape as `/uploads/complete`; enqueues processing |
| POST | `/uploads/multipart/abort` | Discard a pending multipart upload and its stored parts |

The client PUTs each part to its presigned URL and collects the `ETag`
response headers for complete. Every part except the last must be at least
5 MiB. On complete the record's size is reconciled with the real object size
reported by storage. Configure a bucket lifecycle rule
(`AbortIncompleteMultipartUpload`) as a backstop for uploads that are never
completed or aborted.

```lua
local upload_lib = require("userspace.uploads:upload_lib")

local created = upload_lib.create_multipart_upload(user_id, "huge.zip", size)
local urls = upload_lib.multipart_part_urls(user_id, created.upload_id, {1, 2, 3})
-- parts are uploaded out-of-band via the presigned URLs
local upload = upload_lib.complete_multipart_upload(user_id, created.upload_id, {
    { part_number = 1, etag = etag1 },
    { part_number = 2, etag = etag2 },
    { part_number = 3, etag = etag3 },
})
```

## Contract Bindings

Provides content_provider and resource_registry contract implementations:

- `get_content` - Retrieve upload content
- `get_info` - Get upload metadata
- `count_resources` - Count available uploads
- `list_resources` - List uploads with pagination

## License

Apache-2.0
