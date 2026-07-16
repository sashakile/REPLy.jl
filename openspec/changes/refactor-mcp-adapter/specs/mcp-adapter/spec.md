## ADDED Requirements

### Requirement: In-Process Bridge
The MCP adapter SHALL support an in-process bridge mode that calls the server's `handler` closure directly, avoiding a TCP loopback hop. A real-socket mode SHALL be retained as a configurable option for out-of-process deployment. (ARCH-015)

#### Scenario: In-process mode bypasses TCP
- **WHEN** the MCP adapter is in in-process mode
- **THEN** requests are dispatched to the handler closure without creating a TCP connection

### Requirement: Modular MCP Package
The MCP adapter SHALL be split into focused modules: `mcp/tools.jl` (tool catalog), `mcp/requests.jl` (request building), `mcp/results.jl` (result adaptation), and `mcp/server.jl` (server protocol). (ARCH-016)

#### Scenario: Module imports resolve after split
- **WHEN** the MCP adapter is loaded
- **THEN** each sub-module can be imported independently