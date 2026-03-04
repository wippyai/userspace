# userspace/userspace

Userspace components for user management, authentication, and service integrations in Wippy applications.

## Modules

### Core User Management
- **user** - User system constants, configuration, and security tokens
- **contract** - Base contract that all user components must implement
- **credentials** - Provider-specific credential normalization and validation

### Authentication & OAuth
- **oauth** - Generic OAuth 2.0 provider implementation with PKCE support and token refresh
- **component** - Secure component access with validation

### Connections & Integrations
- **connections** - External service connection management
- **mcp** - MCP (Model Context Protocol) client communication

### Content & Knowledge
- **uploads** - File upload handling with content provider and resource registry
- **knowledge** - Universal embeddable interface for knowledge processing
- **docscout** - Document analysis for complex field extraction
- **kb9** - Knowledge base constants

### Workflow & Scheduling
- **scheduler** - Task scheduling contract for deferred execution
- **onboard** - Onboarding step management registry
- **dataflow** - Workflow builder (separate module: wippy/dataflow)

### Search & Discovery
- **webscout** - Google Custom Search API integration

## Installation

```yaml
# In your deps/_index.yaml
- name: __dependency.userspace.userspace
  kind: ns.dependency
  component: userspace/userspace
```

## License

Apache-2.0
