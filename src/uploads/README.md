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
- name: __dependency.userspace.uploads
  kind: ns.dependency
  component: userspace/uploads
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

## Contract Bindings

Provides content_provider and resource_registry contract implementations:

- `get_content` - Retrieve upload content
- `get_info` - Get upload metadata
- `count_resources` - Count available uploads
- `list_resources` - List uploads with pagination

## License

Apache-2.0
