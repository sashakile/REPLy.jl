<!-- vale off -->
# Status

This page tracks the implementation state of REPLy.jl against the canonical OpenSpec definitions.

## Summary

REPLy.jl has progressed significantly beyond its initial tracer-bullet state. The core protocol, session management, and a rich set of middleware-driven operations are now fully implemented and verified.

- **Protocol**: Fully implemented flat JSON envelopes, correlation by `id`, and newline-delimited framing.
- **Operations**: `eval`, `describe`, `load-file`, `interrupt`, `complete`, `lookup`, `stdin`, and full session lifecycle (`new-session`, `ls-sessions`, `close`, `clone`) are all functional.
- **Sessions**: Support for ephemeral and named sessions, binding isolation, FIFO serialization, and Revise.jl integration.
- **Transports**: TCP and Unix domain sockets (with owner-only permissions) are both supported, including concurrent multi-listeners.
- **Adapter**: A complete MCP (Model Context Protocol) reference adapter exists with tool mappings for the core REPLy operations.
- **Security**: Resource limits (connections, sessions, message/output size, eval time) and audit logging are implemented.

## Capability Status Matrix

| Capability | Specified in OpenSpec | Implemented now | Covered now | Notes |
| --- | --- | --- | --- | --- |
| Protocol envelope and JSON framing | ✅ | ✅ | ✅ | Covers flat envelopes, echoed `id`, kebab-case keys, and `done`-terminated streams. |
| Core `eval` flow | ✅ | ✅ | ✅ | Supports `timeout-ms`, `silent`, `store-history`, `allow-stdin`, and `module` path resolution. |
| Additional core operations | ✅ | ✅ | ✅ | `describe`, `load-file`, `interrupt`, `complete`, `lookup`, `stdin`, `clone`, `close`, `ls-sessions` are all built. |
| Session management | ✅ | ✅ | ✅ | Named/ephemeral sessions, FIFO eval, idle timeout sweeping, and Revise integration are complete. |
| Middleware system | ✅ | ✅ | ✅ | Unified `handle_message` protocol with descriptor-based metadata and dynamic stack building. |
| TCP transport | ✅ | ✅ | ✅ | Fully supported with concurrent client handling. |
| Unix socket and multi-listener transport | ✅ | ✅ | ✅ | Support for owner-only sockets, stale cleanup, and `serve_multi`. |
| Error handling | ✅ | ✅ | ✅ | Structured exception metadata, safe `showerror` fallbacks, and comprehensive status flags. |
| Security and resource limits | ✅ | ✅ | ✅ | Limits for connections/sessions/size/time and in-memory/on-disk audit logs are functional. |
| MCP adapter | ✅ | ✅ | ✅ | Eight-tool catalog with status mapping and session routing logic is implemented. |

## Current Implementation Snapshot

| Area | Status | Notes |
| --- | --- | --- |
| TCP/Unix server (`REPLy.serve`) | ✅ implemented | Starts listeners and handles concurrent clients. |
| newline-delimited JSON transport | ✅ implemented | Thread-safe framing and bounded line reading. |
| flat request envelope validation | ✅ implemented | Enforces string `id`, string `op`, kebab-case keys, flat values. |
| `eval` operation | ✅ implemented | Full support for captured I/O, timeouts, and history. |
| Additional ops (`complete`, `lookup`, ...) | ✅ implemented | Handled by modular middleware handlers. |
| buffered `stdout` / `stderr` | ✅ implemented | Piped capture prevents deadlocks on large output. |
| structured error responses | ✅ implemented | Includes `err`, `ex`, and `stacktrace`. |
| unknown op handling | ✅ implemented | Returns `unknown-op` status flag via fallback middleware. |
| concurrent clients | ✅ implemented | Tested across TCP and Unix socket transports. |
| persistent named sessions | ✅ implemented | Full lifecycle management via RPC or Julia API. |
| Revise.jl integration | ✅ implemented | Optional hook to call `revise()` before evals. |
| resource limit enforcement | ✅ implemented | Rejects requests exceeding server-wide constraints. |
| MCP tool catalog | ✅ implemented | Exposes core ops as standard MCP tools. |

## Coverage Map

The project maintains high test coverage (~95%) across unit, integration, and end-to-end layers.

### Unit Coverage

Covered in `test/unit/*`:
- Protocol parsing and bounded line reading.
- Request validation (id/op types, kebab-case, flat envelope).
- Session registry and lifecycle (create/destroy/clone/isolation).
- Every middleware handler (eval, session, describe, complete, lookup, etc.).
- Resource limit enforcement and audit log rotation.
- MCP adapter mapping and stream collection logic.

### Integration & End-to-End Coverage

Covered in `test/integration/*` and `test/e2e/*`:
- Multi-middleware pipeline integration.
- Concurrent client evaluation over TCP.
- Unix domain socket connection and permission checks.
- Multi-listener `serve_multi` scenarios.
- Graceful shutdown with in-flight eval interruption.

## Canonical Spec Index

The canonical capability definitions live in OpenSpec.

- [core-operations spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/core-operations/spec.md)
- [error-handling spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/error-handling/spec.md)
- [mcp-adapter spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/mcp-adapter/spec.md)
- [middleware spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/middleware/spec.md)
- [protocol spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/protocol/spec.md)
- [resource-limits spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/resource-limits/spec.md)
- [security spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/security/spec.md)
- [session-management spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/session-management/spec.md)
- [transport spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/transport/spec.md)

## Remaining Gaps Relative to Spec

- **Heavy Sessions**: Isolation via Malt.jl (planned for post-v1.0).
- **Disconnect Policy**: Explicit connection closure after multiple consecutive malformed messages (currently disconnects on the first error).
- **Editor/Tooling Extensions**: Higher-level client libraries beyond the wire protocol and MCP adapter.

## Commands

```bash
just test        # run the full test suite
just smoke-test  # run the TCP end-to-end smoke test
just check       # run lint, tests, and coverage
```
<!-- vale on -->
