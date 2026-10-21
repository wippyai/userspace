# userspace/uploads

File upload handling with content processing and resource management for Wippy applications.

## Features

- File upload processing pipeline
- Content extraction and storage
- Resource registry integration
- Upload type detection and validation
- Recovery of interrupted processing after restarts
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
  "work is done" (e.g. via its own metadata or a jobs table). Before it
  re-runs, the cursor is marked `active` again, so an interruption during
  the resumed stage is recovered like any other and the upload no longer
  looks parked while it is being worked on. If the
  pipeline definition changed while parked and the recorded stage no longer
  exists, the upload fails explicitly instead of silently re-running
  non-idempotent stages. The cursor is cleared on completion and on error,
  so re-driving a terminal upload runs the full pipeline again. A deferred
  cursor carries `state = "deferred"`, which is what keeps recovery (below)
  from re-queuing the upload.

Between stages the pipeline also records where it stands: after each stage
completes, the cursor names the next one with `state = "active"`. That is what
lets an interrupted run resume instead of starting over.

### Recovery after restarts

The processing queue is in memory, so a restart forgets its messages, and a
worker that dies mid-pipeline (a deploy, an out-of-memory kill) leaves its
upload in `processing` with nobody coming back for it. The uploads table is the
durable record of the work, and `userspace.uploads:recover_pending` reads it
back:

- **At startup** every upload in `uploaded` or `queued` — accepted but never
  picked up — is published to the queue again.
- **At startup and then every `recovery_interval`** every upload in
  `processing` that has not been touched for `recovery_stale_after` is treated
  as interrupted: it is moved to `queued` and published again, and the worker
  that picks it up resumes at the stage its cursor names. After
  `recovery_max_attempts` such re-queues the upload is marked `error` instead,
  because a file that keeps killing its worker must not keep getting one.

Inactivity, not the restart itself, is the signal: in a rolling deployment the
new instance starts while the old one is still working, and treating everything
in `processing` as orphaned would process those uploads twice. The pipeline
refreshes `updated_at` at every stage boundary; a stage that legitimately runs
longer than `recovery_stale_after` (unpacking a large archive, say) must call
`pipeline_lib.heartbeat(upload_id)` every so often to stay off the list.
Deferred uploads are never re-queued by recovery: whatever deferred them owns
their return.

The cursor in `metadata.__pipeline_cursor`:

| Field | Meaning |
|-------|---------|
| `index`, `func` | The stage to run next. `func` wins when the pipeline definition changed. |
| `state` | `active`: a worker was running this stage. `deferred`: waiting for an external re-publish. A cursor without a state (written before this field existed) reads as `deferred`. |
| `recoveries` | How many times an interrupted run was re-queued. Cleared with the cursor on completion and on error. |

Stages should be safe to run twice: an interruption between a stage's side
effects and the cursor write replays that stage.

| Dependency parameter | Default | Meaning |
|----------------------|---------|---------|
| `recovery_stale_after` | `30m` | Inactivity after which a processing upload counts as interrupted (Go duration) |
| `recovery_interval` | `5m` | How often the sweep runs after the startup pass; `0` disables it |
| `recovery_max_attempts` | `3` | Re-queues before an interrupted upload is failed |

A single instance that is stopped before its replacement starts can lower
`recovery_stale_after` for faster recovery; several instances sharing one
database should keep it above their longest stage that does not heartbeat.

### Queue dispatch strategy

The processing queue is shared by every user of the instance and is served in
arrival order, with a fixed number of workers. By default (`queue_strategy:
fifo`) each queue message names the upload to run, so a user who uploads
thirty thousand documents holds everyone else's files behind them until the
workers have been through all of theirs.

With `queue_strategy: fair` a queue message is only a work token: *there is
one more upload to process*. The worker that takes it picks the upload itself,
from the uploads table:

1. the user whose turn it is — among users with an upload in `uploaded` or
   `queued`, the one served longest ago; a user never served goes first, and
   ties go to the user whose upload has been in line longest;
2. that user's upload that has been in line longest — by `updated_at`, the
   moment the row became `uploaded` or `queued`, so a re-driven old document
   joins the back of its owner's line instead of jumping ahead of fresh files;
3. a compare-and-set on the row (`uploaded`/`queued` → `processing`).

The turn is recorded in `upload_turns` (one row per user, the microsecond of
their last claim), so the order is a round-robin over users: two users with
large backlogs alternate, and a single new file from a third user is picked up
by the next free worker. Migration 05 creates `upload_turns` and the index
`uploads(status, user_id, updated_at)` that these lookups run on.

A worker that loses the compare-and-set to another worker pauses for a few
milliseconds and looks again — a lost race means someone else just made
progress, so the loop ends — and never hands the token back for that. It
only gives the token back (nack) after a long run of lost races or after
several database errors, each retried after a pause of about a second, so a
database outage does not become a hot redelivery loop.

Tokens are never fewer than waiting uploads: every row that enters `uploaded`
or `queued` publishes one, a token that finds nothing left to claim is simply
acknowledged, and duplicates — a startup republish on a second instance, a
retry endpoint and a job poller both re-queuing the same upload — only cost a
claim attempt, because the compare-and-set runs each upload once. A token can
still be lost (a publish that failed, a nack the full queue could not take
back), so in `fair` mode the recovery sweep also republishes tokens for
uploads that have waited untouched for longer than `recovery_stale_after`,
at most 500 per pass and only while the queue is empty; surplus tokens are
harmless, so the check errs on the side of publishing.

Switch strategies only with a drained queue: `fifo` workers run the upload a
message names without a compare-and-set, so tokens left over from `fair`
would run uploads that other tokens already claimed.

Anything that returns a parked upload to the queue — a job poller after an
asynchronous stage, a retry endpoint — must put it back in line rather than
publish its id directly, because in `fair` mode the id in a message is not
what runs:

```lua
local upload_lib = require("userspace.uploads:upload_lib")

local ok, err = upload_lib.requeue(upload_id)
```

`requeue` moves the row to `queued`, notifies the owner, and publishes one
token; the run then resumes at the stage its cursor names. It refuses a
`pending` row (a presigned upload whose bytes have not arrived) and a
`processing` row that is still being worked on — one whose cursor is not
deferred and whose `updated_at` is newer than `recovery_stale_after` — because
queuing a running upload would run it twice; `{ force = true }` overrides that
for an operator who knows better. A caller that has just written to the row
itself — a resume cursor, cleared flags — has made it look active and must
pass `force` with its own reason for believing nothing is running. It works
the same way under both
strategies, so callers can switch to it before the strategy changes. If the
publish fails, the row stays `queued` and the startup pass of recovery
publishes it again.

| Dependency parameter | Default | Meaning |
|----------------------|---------|---------|
| `queue_strategy` | `fifo` | `fifo`: run the upload each message names, in arrival order. `fair`: round-robin over users; each message is a work token |

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
