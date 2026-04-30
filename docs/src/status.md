<!-- vale off -->
# Status

This page tracks three different things:

- what REPLy currently implements
- what automated checks currently cover
- what the canonical OpenSpec capability specs define

OpenSpec note:

- `openspec/specs/` describes the canonical capability definitions for the project
- the current codebase does not yet implement all of that specified surface
- the GitHub links below intentionally point to `main`

## Summary

Current tracer-bullet state:

- core TCP `eval` flow is implemented end to end
- unit, integration, end-to-end, docs build, and smoke-test coverage all exist
- CI runs repository checks plus the TCP smoke test
- the current implementation covers only a small subset of the specified protocol surface

## Capability Status Matrix

| Capability | Specified in OpenSpec | Implemented now | Covered now | Notes |
| --- | --- | --- | --- | --- |
| Protocol envelope and JSON framing | ✅ | ✅ partial | ✅ | Current code covers flat envelopes, echoed `id`, newline-delimited JSON, and done-terminated streams |
| Core `eval` flow | ✅ | ✅ partial | ✅ | Basic `eval` works; richer options like `timeout-ms`, `silent`, `store-history`, and `allow-stdin` are not implemented |
| Additional core operations | ✅ | ❌ | ❌ | `describe`, `load-file`, `interrupt`, `complete`, `lookup`, `stdin`, `clone`, `close`, `ls-sessions` remain to be built |
| Session management | ✅ | ✅ partial | ✅ partial | Ephemeral sessions exist; named sessions, lifecycle ops, pooling, idle timeout, and Revise integration do not |
| Middleware system | ✅ | ✅ partial | ✅ partial | Basic stack exists; descriptor metadata and startup dependency validation do not |
| TCP transport | ✅ | ✅ | ✅ | Current implementation target |
| Unix socket and multi-listener transport | ✅ | ✅ | ✅ partial | `socket_path` arg to `serve()`, `serve_multi()`, `listen_unix()`; owner-only permissions; stale-socket cleanup |
| Error handling | ✅ | ✅ partial | ✅ | Structured errors and unknown-op exist; repeated-malformed disconnect policy and richer status taxonomy do not |
| Security and resource limits | ✅ | ❌ | ❌ | Limits, audit logging, shutdown, and rate limiting are specified but not implemented |
| MCP adapter | ✅ | ❌ | ❌ | Fully specified but not started |

## Current Implementation Snapshot

| Area | Status | Notes |
| --- | --- | --- |
| TCP server (`REPLy.serve`) | ✅ implemented | Starts a listener and handles concurrent clients |
| newline-delimited JSON transport | ✅ implemented | `send!` and `receive` cover framing |
| flat request envelope validation | ✅ implemented | Enforces string `id`, string `op`, kebab-case keys, flat values |
| `eval` operation | ✅ implemented | Evaluates code in an ephemeral module |
| buffered `stdout` / `stderr` | ✅ implemented | Output is emitted before terminal value and done |
| structured error responses | ✅ implemented | Includes `err`, `ex`, and `stacktrace` when available |
| unknown op handling | ✅ implemented | Returns `unknown-op` status flag |
| concurrent clients | ✅ implemented | Covered by end-to-end TCP tests |
| malformed JSON boundary handling | ✅ implemented | Connection closes without a protocol response |
| persistent named sessions | ❌ not implemented | Only ephemeral sessions exist today |
| operations beyond `eval` | ❌ not implemented | No richer protocol surface yet |
| editor/tooling integration layer | ❌ not implemented | Wire protocol only for now |

## Canonical Spec Index

The canonical capability definitions live in OpenSpec. These are the GitHub sources for each capability:

- [core-operations spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/core-operations/spec.md)
- [error-handling spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/error-handling/spec.md)
- [mcp-adapter spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/mcp-adapter/spec.md)
- [middleware spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/middleware/spec.md)
- [protocol spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/protocol/spec.md)
- [resource-limits spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/resource-limits/spec.md)
- [security spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/security/spec.md)
- [session-management spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/session-management/spec.md)
- [transport spec](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/transport/spec.md)

### Protocol

Spec: [openspec/specs/protocol/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/protocol/spec.md)

Specified protocol features and scenarios include:

- flat JSON envelopes with `op`, `id`, and optional `session`
- bounded request IDs with rejection of oversized IDs
- mandatory response correlation by echoed `id`
- exactly one `done` terminator per request stream
- intra-request ordering guarantees (`out` / `err` before `value`, then `done`)
- streaming multi-message responses for a single request
- tolerance of unknown fields for forward compatibility
- kebab-case wire keys only
- newline-delimited JSON as the default wire encoding
- connection-time encoding selection for future transport variants
- status-flag semantics and unknown-flag tolerance
- UUIDv4 session IDs generated from secure randomness
- explicit disambiguation between stderr chunks and terminal error payloads

Representative specified scenarios:

- valid requests with and without `session`
- oversized IDs rejected but IDs at the limit accepted
- no double-`done` on parse error
- multiple stdout chunks before `done`
- clients ignoring unknown flags
- clone-generated session IDs matching UUIDv4 format

### Core Operations

Spec: [openspec/specs/core-operations/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/core-operations/spec.md)

Specified built-in operations:

- `describe`
- `eval`
- `load-file`
- `interrupt`
- `complete`
- `lookup`
- `stdin`
- `close`
- `clone`
- `ls-sessions`
- unknown-op fallback and malformed-input handling

Specified `eval` behavior goes beyond the current tracer bullet:

- session-targeted eval
- stdout/stderr streaming before terminal value
- empty-code behavior returning `nothing`
- module-path resolution such as `Main.Foo.Bar`
- `allow-stdin:false` causing immediate `EOFError`
- `timeout-ms` validation and capping
- `silent:true` suppressing `value`
- `store-history:false` avoiding history / `ans` updates
- large `repr` truncation with a `truncated:true` flag

Other specified operation scenarios include:

- `describe` returning supported ops, middleware, versions, and encodings
- `load-file` enforcing allowlists and preserving source file context
- `interrupt` handling targeted and broadcast cancellation
- `complete` returning completions or empty results for out-of-bounds positions
- `lookup` returning docs/methods or `found:false`
- `stdin` unblocking waiting evals or buffering input when no eval is waiting
- `close` returning `session-closed` or `session-not-found`
- `clone` creating empty, light, and heavy sessions with explicit cloning rules
- `ls-sessions` returning active-session metadata
- malformed input handling for invalid JSON, missing `op`, and missing `id`

### Session Management

Spec: [openspec/specs/session-management/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/session-management/spec.md)

Specified session features:

- light sessions backed by isolated anonymous `Module`s
- parallelism across different sessions
- FIFO eval serialization within a single session
- `eval_task` publication early enough for interrupts to observe it
- low-latency session creation targets
- optional heavy sessions via Malt.jl
- idle timeout with background sweeping
- ephemeral sessions for session-omitting execution ops
- pooled anonymous modules for bounded ephemeral-session memory growth
- an atomic lifecycle state machine (`CREATED`, `ACTIVE`, `EVAL_RUNNING`, `DESTROYED`)
- Revise.jl integration before eval

Representative specified scenarios:

- bindings isolated across two named sessions
- same-session eval requests complete in FIFO order
- idle sessions close automatically while in-flight evals are spared
- ephemeral evals do not appear in `ls-sessions`
- ephemeral requests count against session and concurrency limits
- competing `close`, `timeout`, and `interrupt` causes resolve exactly once
- heavy-session requests fail when Malt.jl is unavailable

### Middleware

Spec: [openspec/specs/middleware/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/middleware/spec.md)

Specified middleware-system features:

- a uniform `handle_message(mw, msg, next, ctx)` protocol
- streaming intermediate responses through a response sink
- third-party operation registration without modifying core code
- middleware descriptors with `provides`, `requires`, `expects`, and per-op metadata
- startup validation for duplicate providers and ordering constraints
- a nine-middleware default stack
- stack immutability after startup
- guard behavior for empty response vectors
- per-connection handler caching

Representative specified scenarios:

- pass-through for unknown operations
- custom middleware implementing a new operation such as `set-breakpoint`
- startup failure on duplicate `:eval` providers
- all descriptor errors reported together rather than fail-fast
- default stack including describe, session, eval, interrupt, load-file, completion, lookup, stdin, and unknown-op middleware

### Transport

Spec: [openspec/specs/transport/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/transport/spec.md)

Specified transport features:

- a four-method abstract transport interface: `send!`, `receive`, `close`, `isopen`
- postconditions for `receive` on partial reads, disconnects, and non-object JSON
- TCP transport with thread-safe sends
- Unix domain socket transport with owner-only permissions
- newline-delimited JSON transport as the default encoding
- transport-agnostic middleware / session / operation layers
- multi-listener support, including TCP and Unix socket concurrently

Representative specified scenarios:

- a custom transport such as `WebSocketTransport` working unchanged with core logic
- TCP accept-loop startup and port-conflict behavior
- restrictive Unix socket creation without a permission race window
- removal of stale socket files at startup
- global resource limits shared across multiple listeners

### Error Handling

Spec: [openspec/specs/error-handling/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/error-handling/spec.md)

Specified error-handling features:

- a canonical error payload shape with `err`, optional `ex`, optional `stacktrace`, and optional `cause`
- safe extraction of exception messages even when exceptions have no `.msg` field
- explicit status flags for categories like `timeout`, `rate-limited`, `session-not-found`, and `concurrency-limit-reached`
- distinct interrupt termination semantics (`interrupted` without `error`)
- connection closure after repeated malformed messages

Representative specified scenarios:

- runtime and parse errors with structured exception metadata
- exceptions without `.msg` falling back to `showerror`
- client-visible distinction among timeout, rate-limit, session-limit, and unknown-op failures
- ten consecutive malformed messages causing disconnect
- a valid request resetting the malformed-message counter

### Security and Resource Limits

Sources:

- [openspec/specs/security/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/security/spec.md)
- [openspec/specs/resource-limits/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/resource-limits/spec.md)

Specified security and limit features:

- owner-only Unix socket access
- enforcement of server-wide resource limits
- eval timeout behavior with latency targets
- session-count and concurrent-eval enforcement
- maximum message size enforcement by connection close
- per-connection rate limiting
- bounded per-session history
- startup warnings for dangerously low rate limits
- bounded in-memory and rotating on-disk audit logs
- orphan-eval cleanup on client disconnect
- per-task stdout/stderr capture to prevent cross-session leakage
- closed-channel-safe response sending
- graceful shutdown with interruption, draining, and listener cleanup

Representative specified scenarios:

- timeout and manual interrupt racing against the same eval
- queueing concurrent evals up to a bounded limit and rejecting overflow
- oversized messages closing the connection with audit logging
- disconnect cancelling a running eval instead of leaking work forever
- concurrent sessions emitting stdout without cross-stream leakage
- shutdown succeeding within the grace period or force-closing after it expires

### MCP Adapter

Spec: [openspec/specs/mcp-adapter/spec.md](https://github.com/sashakile/REPLy.jl/blob/main/openspec/specs/mcp-adapter/spec.md)

Specified MCP-facing features:

- a reference adapter that speaks MCP on one side and REPLy over Unix socket on the other
- declaration of the supported MCP protocol version during `initialize`
- an eight-tool catalog:
  - `julia_eval`
  - `julia_complete`
  - `julia_lookup`
  - `julia_load_file`
  - `julia_interrupt`
  - `julia_new_session`
  - `julia_list_sessions`
  - `julia_close_session`
- a persistent default session owned by the adapter
- sentinel-based ephemeral mode
- REPLy-to-MCP status mapping rules

Representative specified scenarios:

- end-to-end MCP eval returning `2` for `1+1`
- `tools/list` showing all eight tools
- `julia_eval` surfacing stdout as tool content
- stdin-blocking code failing fast in MCP via `allow-stdin:false`
- omitted session arguments routing to a persistent default session
- REPLy `timeout`, `interrupted`, and `session-not-found` statuses mapping to MCP `isError = true`

## Coverage Map

This section is organized by test layer. Use the capability matrix above to map these checks back to the corresponding specs.

### Unit Coverage

Covered in `test/unit/*`:

- protocol identity and version helpers
- JSON message framing and parsing
- blank-line skipping
- malformed JSON treated as a closed boundary
- partial reads and disconnect handling
- request validation failures:
  - oversized ids
  - empty ids
  - non-string ids
  - missing `op`
  - non-string `op`
  - snake_case keys
  - nested request values
- response helper behavior
- session lifecycle:
  - create / destroy
  - idempotent destroy
  - multiple sessions
  - binding isolation across anonymous modules
- middleware behavior:
  - pass-through for unhandled ops
  - `eval` interception
  - fallback cleanup without leaks
- eval middleware behavior:
  - buffered stdout ordering
  - buffered stderr ordering
  - empty code returns `nothing`
  - runtime error classification
  - large output without deadlock
- structured error payloads and unknown-op responses

### Integration Coverage

Covered in `test/integration/pipeline_test.jl`:

- successful tracer-bullet pipeline returns buffered stdout before value and done
- unknown operation returns structured `unknown-op` error
- parse errors return structured exception metadata
- eval errors return structured exception metadata
- ephemeral eval flow does not leak sessions
- large buffered stdout preserves terminal value and completes

### End-to-End TCP Coverage

Covered in `test/e2e/eval_test.jl`:

- single client receives value then done
- two concurrent clients each receive their own done-terminated stream
- server survives a client disconnect during eval
- malformed JSON closes the connection without a protocol response

### Smoke-Test Coverage

Covered by `scripts/smoke-test.jl` and run with `just smoke-test`:

- successful `eval` over TCP
- structured runtime error response over TCP
- malformed-JSON disconnect behavior over TCP

## Commands

```bash
just test
just smoke-test
just check
```

- `just test` runs the Julia test suite
- `just smoke-test` runs the end-to-end TCP smoke test against a temporary server
- `just check` runs lint, workflow lint, tests, smoke test, and coverage

## Current Gaps Relative to Spec

Important areas that are specified but not yet implemented, or only partially implemented, include:

- named-session lifecycle operations (`clone`, `close`, `ls-sessions`)
- additional core operations (`describe`, `load-file`, `interrupt`, `complete`, `lookup`, `stdin`)
- middleware descriptors and startup dependency validation
- multi-listener transport test coverage (Unix socket and `serve_multi` work but lack dedicated test scenarios)
- security enforcement for limits, rate limiting, and audit logging
- idle timeouts, session serialization, and Revise integration
- MCP adapter and tool mapping layer

## Next Good Scenarios to Add

Likely next additions for the implementation and test suite:

1. `describe` and named-session lifecycle tests
2. timeout / interrupt race handling
3. session FIFO serialization and idle-timeout behavior
4. Unix socket transport end-to-end tests and `serve_multi` scenario coverage
5. resource-limit enforcement and audit-log scenarios
6. MCP adapter conformance once the adapter exists
<!-- vale on -->
