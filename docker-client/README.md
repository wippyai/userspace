# Docker HTTP client

`userspace/docker-client` provides the
`userspace.docker.client:client` library. It depends only on the runtime's
`http_client`, `json`, and `time` modules. Installing this package creates no
services, databases, migrations, or Docker connections. The host selects permissions;
importing the library grants none.

Declare a dependency on `userspace/docker-client` and import
`userspace.docker.client:client` to use the client. Calling `new` may probe Docker;
callers should supply their selected socket explicitly. The implementation and
method signatures are unchanged from `userspace/docker`.

The `userspace/docker` package adds the service, storage and contract layer and
depends on this package. Its existing `userspace.docker:docker_client` library
re-exports this client, preserving current imports. There is one implementation.
Client protocol tests remain in that package's test harness and are not
dependencies of this library package.

Run `make check WIPPY=/path/to/wippy` for standalone lint and a disposable Unix
socket fixture that verifies successful inspection, a Docker 404 response, and
a transport failure with no HTTP status. It resolves this package through a
local workspace replacement and never accesses a real Docker daemon.
