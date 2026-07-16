# Change: Add first-class REPLy.Client (Part C)

## Why

The wire protocol is implemented 4× (replyc, MCP, qa, tutorial). Each implementation duplicates connection logic, message framing, and error handling. A single `REPLy.Client` type reduces duplication and provides a canonical reference for third-party clients.

## What Changes

- Extract `REPLy.Client` with connection, send, receive, and disconnect methods
- Re-point replyc, MCP adapter, qa harness, and tutorial to use `REPLy.Client`
- Wire protocol implementation count: 4 → 1

## Impact

- Affected specs: `protocol` (new client requirement)
- Affected code: `src/client.jl` (new), replyc, MCP, test/qa, tutorial
- Depends on: nothing (can be done in parallel with other structural work)
