# Change: Refactor MCP adapter — drop loopback hop, split god-file (B8)

## Why

The MCP adapter reaches the in-process server over a real TCP loopback socket (not out-of-process). This adds unnecessary latency and complexity. The 667-line `mcp_adapter.jl` is a god-file with 5 distinct responsibilities.

## What Changes

- Have the in-process bridge call the `handler` closure directly (drop the socket hop)
- Keep a real-socket mode as an option for out-of-process use cases
- Split `mcp_adapter.jl` into `mcp/{tools,requests,results,server}.jl`

## Impact

- Affected specs: `mcp-adapter`
- Affected code: `src/mcp_adapter.jl` → `src/mcp/*.jl`
- Depends on: `add-first-class-client` (the extracted `REPLy.Client` would be used by MCP)