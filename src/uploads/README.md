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

Upload types declare a `pipeline:` list of stages; the module runs them in
order through the `funcs` executor:

```yaml
- name: types.my_documents
  kind: registry.entry
  meta:
    type: upload.type
  extensions: [pdf]
  mime_types: [application/pdf]
  pipeline:
    - title: Extracting Text
      func: app.uploads:extract
    - title: OCR Processing
      func: app.uploads:ocr
```

Each stage function receives `{ upload_id, mime_type, storage_id,
storage_path, size, metadata, processor_id }` and may finish in one of three
ways:

- **Success** — any non-nil result. `result.success` is not inspected. A
  returned `metadata` table is merged into the upload's metadata and
  persisted immediately, so later stages and later runs can read it.
- **Failure** — a raised error (or `nil, err`). The upload is marked
  `error` and the error callback fires.
- **Defer** — `{ defer = true, metadata = {...} }` parks the upload:
  metadata plus a resume cursor are persisted, the upload stays in
  `processing`, no completion/error callbacks fire and the queue message is
  acked (the worker is freed). Something external (a job poller, a
  dispatcher) must later re-publish `{"upload_id": "..."}` to
  `userspace.uploads:process_queue`; the run then resumes from the deferred
  stage, skipping the stages before it. The deferring stage re-runs on
  resume and is responsible for telling "start async work" apart from
  "work is done" (e.g. via its own metadata or a jobs table). If the
  pipeline definition changed while parked and the recorded stage no longer
  exists, the upload fails explicitly instead of silently re-running
  non-idempotent stages. The cursor is cleared on completion and on error,
  so re-driving a terminal upload runs the full pipeline again.

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
