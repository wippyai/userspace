# userspace/docker

Docker container and image management via contracts and process messaging.

## Features

- Container lifecycle management (create, start, stop, delete)
- Image operations (pull, build, list, delete)
- Network and volume management
- Port mapping (host:container)
- Live log streaming via process messaging
- Interactive and managed execution modes
- Compose-style multi-container groups
- Declarative containers via registry entries (auto-start on boot)
- Dynamic pickup of new container entries at runtime via registry events

## Installation

```yaml
- name: dependency.docker
  kind: ns.dependency
  component: userspace/docker
  version: ">=0.2.0"
```

## Requirements

| Requirement | Default | Description |
|-------------|---------|-------------|
| `database` | `app:db` | Database resource for container and image storage |
| `process_host` | `app:processes` | Process host for docker services |

## Interactive executor routes

Acknowledged, multi-write stdin uses Wippy's attached Docker executor. It is
enabled only by a registry allowlist; callers cannot select an executor. The
route image and the `exec.docker` image must be exactly equal. Digest-addressed
images are recommended so a mutable tag cannot change the sandbox between runs.

```yaml
entries:
  - name: agent_executor
    kind: exec.docker
    image: registry.example/agent@sha256:0123...
    auto_remove: true
    read_only_rootfs: true
    no_new_privileges: true

  - name: agent_interactive_route
    kind: registry.entry
    meta:
      type: docker.interactive_executor
    image: registry.example/agent@sha256:0123...
    executor: app:agent_executor
```

The service validates every route at startup and again immediately before
process creation. Missing, duplicated, replaced, non-Docker, or image-mismatched
routes fail closed. The chosen route and executor IDs are persisted on the
container, and stdin operation receipts identify that exact executor backend.

## Declarative Containers

Register containers as `registry.entry` with `meta.type: docker.container`. The docker root process picks them up at startup and whenever a new entry is created at runtime.

This works like docker-compose: any wippy component can declare containers in its `_index.yaml`, and they start automatically when the component is installed.

### Single container

```yaml
entries:
  - name: my_redis
    kind: registry.entry
    meta:
      type: docker.container
    image: redis:7
    command: redis-server --appendonly yes
    ports:
      - { host: 6379, container: 6379 }
    restart_policy: unless-stopped
```

### Services vs jobs

A `restart_policy` marks a container as a **long-lived service**: the worker
starts it, confirms it is up, then hands it off to Docker's restart policy and
the monitor — it is never polled to completion or removed. A stopped/failed
service is recreated on the next startup. Without a `restart_policy` the
container is treated as a **finite job**: it is polled until it exits, its logs
and exit code are recorded, and it is removed.

### Multi-service stack

```yaml
entries:
  - name: postgres_db
    kind: registry.entry
    meta:
      type: docker.container
    image: postgres:16
    command: postgres
    env:
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: myapp
    ports:
      - { host: 5432, container: 5432 }
    network: myapp-net

  - name: app_server
    kind: registry.entry
    meta:
      type: docker.container
    image: myapp:latest
    command: ./server --db postgres_db:5432
    env:
      DATABASE_URL: postgres://postgres:secret@postgres_db:5432/myapp
    ports:
      - { host: 8080, container: 8080 }
    network: myapp-net

  - name: nginx_proxy
    kind: registry.entry
    meta:
      type: docker.container
    image: nginx:latest
    command: nginx -g 'daemon off;'
    ports:
      - { host: 80, container: 80 }
      - { host: 443, container: 443 }
    network: myapp-net
    volumes:
      - { host: /etc/nginx/conf.d, container: /etc/nginx/conf.d, mode: ro }
```

### Available fields

| Field | Type | Description |
|-------|------|-------------|
| `image` | string | Docker image (default: `alpine:latest`) |
| `command` | string | Shell command, wrapped as `sh -c` (provide this or `args`) |
| `args` | array? | Raw Cmd args passed to the image entrypoint, no `sh -c` wrap (e.g. `["--http","--port","3001"]` for an ENTRYPOINT-based server image). Takes precedence over `command`. |
| `entrypoint` | array? | Override the image ENTRYPOINT |
| `name` | string? | Container name |
| `env` | map | Environment variables |
| `ports` | array | Port mappings: `{host, container, protocol?}` |
| `network` | string? | Docker network name |
| `volumes` | array | Volume mounts: `{host, container, mode?}` |
| `work_dir` | string? | Working directory inside container |
| `interactive` | boolean? | Enable stdin for interactive containers |
| `labels` | map? | Container labels |

### How it works

1. A wippy component declares `docker.container` entries in its `_index.yaml`
2. On install (`wippy install`), entries appear in the registry
3. The docker root process detects new entries via registry events
4. Containers are created in the database and picked up by workers
5. Workers pull images (if needed) and start containers via Docker API

No manual orchestration required. Install a component, containers start.

## Contracts

### `userspace.docker:containers`

```lua
local docker = contract.open("userspace.docker:containers")

-- Create a container
local result = docker:create({
    image = "alpine:latest",
    command = "echo hello",
    name = "my-container",
    env = { MY_VAR = "value" },
    ports = { { host = 8080, container = 80 } },
    network = "my-network",
    stream = { reply_to = process.self(), topic = "docker.logs" },
})

-- Get container by ID
local result = docker:get({ id = container_id })

-- List containers
local result = docker:list({ status = "running", limit = 10 })

-- Read a bounded page after an exclusive per-container cursor. Each line has
-- both a global log_id and a contiguous container-local sequence.
local result = docker:logs({ id = container_id, cursor = 0, limit = 100 })
local next_cursor = result.next_cursor

-- Record-before-send stdin for an interactive executor. `dispatched` is not
-- delivery: poll stdin_status until delivered/failed/uncertain. Managed Docker
-- containers currently return `unsupported` because the package has no
-- attach-stream acknowledgement and never fabricates success.
local write = docker:stdin({
    container_id = id,
    data = "input\n",
    operation_id = "turn-42",
    request_digest = "sha256:...",
})
local status = docker:stdin_status({ operation_id = "turn-42" })

-- Delete container
docker:delete({ id = container_id })

-- Create multiple containers on a shared network
local result = docker:compose({
    name = "my-group",
    network = "my-net",
    containers = {
        { image = "redis:latest", command = "redis-server", ports = { { host = 6379, container = 6379 } } },
        { image = "alpine:latest", command = "echo done" },
    },
})
```

### `userspace.docker:networks`

```lua
local networks = contract.open("userspace.docker:networks")

networks:create({ name = "my-network", driver = "bridge" })
local result = networks:list({})
networks:remove({ id = network_id })
```

### `userspace.docker:volumes`

```lua
local volumes = contract.open("userspace.docker:volumes")

volumes:create({ name = "my-volume", driver = "local" })
local result = volumes:list({})
volumes:remove({ name = "my-volume" })
```

### `userspace.docker:images`

```lua
local images = contract.open("userspace.docker:images")

-- List images
local result = images:list()

-- Pull an image
local result = images:pull({ image = "alpine", tag = "latest" })

-- Build from Dockerfile
local result = images:build({
    name = "my-app",
    tag = "v1",
    dockerfile = "FROM alpine\nRUN echo hello",
    stream = { reply_to = process.self(), topic = "build.logs" },
})

-- Check build status
local result = images:build_status({ build_id = build_id })

-- Delete an image
images:delete({ id = image_id })
```

### `userspace.docker:narrow`

This contract is for orchestrators that already produce a complete protected
Docker API configuration. It accepts only immutable images, non-root users,
read-only root filesystems, dropped capabilities, no-new-privileges,
seccomp/AppArmor, positive PID/CPU/memory limits, non-host networking, bounded
binds, one hardened tmpfs, and exact `bee.*` attempt labels. Unknown or broader
Docker fields fail closed.

```lua
local narrow = contract.open("userspace.docker:narrow")
local created = narrow:create({ name = "bee-<digest>", config = protected_config })
narrow:start({ backend_ref = created.backend_ref })
local observed = narrow:inspect({ backend_ref = created.backend_ref })
narrow:stop({ backend_ref = created.backend_ref, timeout_seconds = 10 })
narrow:remove({ backend_ref = created.backend_ref })
```

The narrow surface is a low-level enforcement boundary, not a second
general-purpose container API. `ExtraHosts` is empty by default and permits
only the fixed Linux bridge mapping `host.docker.internal:host-gateway`; all
caller-selected aliases and addresses remain rejected.

## Streaming Events

Methods that accept a `stream` parameter deliver live events via process messaging:

```lua
local result = docker:create({
    image = "alpine:latest",
    command = "echo hello",
    stream = { reply_to = process.self(), topic = "my.events" },
})

local ch = process.listen("my.events")
while true do
    local ev = ch:receive()
    if ev.type == "done" then break end
    if ev.type == "log" then
        print(ev.stream .. ": " .. ev.line)
    elseif ev.type == "status" then
        print("status: " .. ev.status)
    end
end
```

## License

Apache-2.0
