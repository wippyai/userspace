# MCP Integration Specification - Dense Reference

> Make sure that MCP server is launchable. User must confirm server works independently before integrating with agent.

## Core Architecture

**Components:** MCP Server Process → `userspace.mcp:client` → `userspace.mcp.traits:client` → Agent Tools

**Flow:** Server Registration → Client Connection → Tool Discovery → Dynamic Tool Creation → Agent Integration

---

## Server Registration

```yaml
- name: {server_name}.service
  kind: process.service
  host: app:processes
  input:
    - name: {server_identifier}        # Must match trait context server_id
      executable: {command}            # npx, python, binary path
      args: [{server_package}, {args}] # MCP server specific
  lifecycle:
    auto_start: true
  process: userspace.mcp.service:exec  # Required executor
```

**Examples:**
```yaml
# Filesystem
- name: fs_server.service
  input:
    - name: filesystem_server
      executable: npx
      args: ['@modelcontextprotocol/server-filesystem', '/workspace']

# Custom Python
- name: db_server.service  
  input:
    - name: database_server
      executable: python
      args: ['/path/to/server.py', '--config', '/path/config.json']
```

---

## Agent Trait Configuration

### Required Context
```yaml
traits:
  - id: userspace.mcp.traits:client
    context:
      server_id: {server_identifier}  # REQUIRED: matches process service name
```

### Full Configuration Schema
```yaml
traits:
  - id: userspace.mcp.traits:client
    context:
      server_id: string              # REQUIRED: MCP server identifier
      integration_mode: string       # "individual_tools" | "command_caller" | "unified_tool"
      tool_prefix: string           # Prefix for generated tool names
      tool_name: string             # Name for individual_tools mode tool
      selected_tools: [string]      # Filter to specific MCP tools only
```

### Integration Modes

**individual_tools** (default): Single tool with real schemas, tool selection via parameters
```yaml
context:
  server_id: filesystem_server
  integration_mode: individual_tools
  tool_name: mcp_tools              # Default: "mcp_tools"
```

**command_caller**: Individual pre-bound tools with flexible schemas per MCP tool
```yaml
context:
  server_id: filesystem_server  
  integration_mode: command_caller
  tool_prefix: fs_                  # Creates: fs_read_file, fs_write_file, etc.
```

**unified_tool**: Legacy single tool that can call any MCP tool
```yaml
context:
  server_id: filesystem_server
  integration_mode: unified_tool
```

---

## Client Library API

### Connection
```lua
local mcp_client = require("mcp_client")
local client, err = mcp_client.connect("server_identifier")
```

### Operations
```lua
-- Health check
local pong, err = mcp_client.ping(client)

-- Get available tools  
local tools, err = mcp_client.get_tools(client)

-- Execute tool
local result, err = mcp_client.call_tool(client, "tool_name", {
    param1 = "value1",
    param2 = "value2"
})

-- Cleanup
mcp_client.close(client)
```

### Function Schemas

**MCPGetInfo:**
```json
{
  "server_id": "string (required)"
}
```
Returns: `{success: bool, server_info: {server_id, connected, ping_successful, tools, tools_count, status}}`

**MCPCallTool:**
```json
{
  "server_id": "string (required)",
  "tool_name": "string (required)", 
  "parameters": "object (optional)"
}
```
Returns: `{success: bool, call_result: {server_id, tool_name, tool_result}}`

---

## Configuration Constants

### Environment Variables
```lua
ENV_IDS = {
    EXECUTOR_ID = "userspace.mcp.env:executor_id",           # Default: "userspace.mcp:executor"
    PROTOCOL_VERSION = "userspace.mcp.env:protocol_version", # Default: "2024-11-05"
    CLIENT_NAME = "userspace.mcp.env:client_name",           # Default: "wippy-mcp-client"
    CLIENT_VERSION = "userspace.mcp.env:client_version"      # Default: "1.0.0"
}
```

### Timeouts & Limits
```lua
DEFAULTS = {
    RESPONSE_TIMEOUT_MS = 10000,      # Standard request timeout
    TOOL_CALL_TIMEOUT_MS = 300000,    # Tool execution timeout (5min)
    REQUEST_TIMEOUT_MS = 30000,       # Request processing timeout
    INIT_DELAY_MS = 1000,             # Server initialization delay
    SHUTDOWN_DELAY_MS = 2000          # Graceful shutdown delay
}
```

---

## Security & Access Control

**Permission Required:** `mcp.connect` for resource `mcp.client.{server_name}`

**Access Verification:**
```lua
local allowed = security.can("mcp.connect", "mcp.client." .. server_name)
```

**Error Handling:**
- `"Access denied to MCP service: {name}"` - Security check failed
- `"Failed to connect to MCP server"` - Server unavailable
- `"Server not responding"` - Ping timeout
- `"Tool call failed"` - Tool execution error

---

## Complete Agent Example

```yaml
- name: mcp_assistant
  kind: registry.entry
  meta:
    type: agent.gen1
    title: MCP-Enabled Assistant
  prompt: |
    You are an assistant with MCP server access. Use available tools for file operations,
    database queries, or other server-specific functionality as requested.
  model: claude-4-sonnet
  temperature: 0.3
  traits:
    - id: userspace.mcp.traits:client
      context:
        server_id: filesystem_server
        integration_mode: command_caller
        tool_prefix: fs_
        selected_tools: ["read_file", "write_file", "list_directory"]
  memory:
    - I have access to MCP tools for extended functionality
    - I should explain tool usage and results clearly
```

---

## Implementation Notes

**Registry Namespace:** `userspace.mcp.*`
**Topic Pattern:** `{server_id}.request` / `{server_id}.response.{request_id}`
**Process Executor:** `userspace.mcp.service:exec` (required)
**Build Function:** `userspace.mcp.traits:init_mcp_integration` (handles dynamic tool creation)

**Tool Discovery Flow:**
1. Trait binding triggers build function
2. Client connects to MCP server via executor
3. Server tools enumerated via `tools/list` operation
4. Dynamic tool creation based on integration_mode
5. Tools registered with agent's capability set

**Best Practices:**
- Always use `command_caller` mode for multiple distinct tools
- Use `individual_tools` mode for unified tool selection interface
- Set appropriate `tool_prefix` to avoid naming conflicts
- Filter with `selected_tools` to limit exposed functionality
- Handle MCP server failures gracefully with fallback behavior