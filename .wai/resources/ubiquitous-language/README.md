# REPLy.jl — Ubiquitous Language

This tree defines the canonical vocabulary for the REPLy.jl project.
Use these names consistently across specs, code, docs, PR descriptions, and
conversations. When a term is used ambiguously in an external source, translate
it to this glossary before reasoning about it.

## Bounded Contexts

| File | Context | One-line scope |
|------|---------|---------------|
| [contexts/protocol.md](contexts/protocol.md) | **Protocol** | Wire format: messages, fields, status flags, encoding |
| [contexts/session.md](contexts/session.md) | **Session** | Execution namespaces, lifecycle, isolation |
| [contexts/middleware.md](contexts/middleware.md) | **Middleware** | Pluggable operation routing pipeline |
| [contexts/evaluation.md](contexts/evaluation.md) | **Evaluation** | Julia code execution, I/O capture, result handling |
| [contexts/transport.md](contexts/transport.md) | **Transport** | Network layer: TCP, Unix sockets, connections |
| [contexts/security.md](contexts/security.md) | **Security** | Resource limits, rate limiting, audit logging |
| [contexts/errors.md](contexts/errors.md) | **Errors** | Structured failure taxonomy and response shape |
| [contexts/intelligence.md](contexts/intelligence.md) | **Intelligence** | Completions, documentation lookup, symbol resolution |
| [contexts/mcp.md](contexts/mcp.md) | **MCP Adapter** | Protocol bridge to Model Context Protocol clients |
| [contexts/server.md](contexts/server.md) | **Server** | Lifecycle, connection management, shutdown |

## Overloaded Terms — Disambiguation

Some words appear in multiple contexts with distinct meanings. This table is the authoritative disambiguation:

| Word | Where | Meaning |
|------|-------|---------|
| **context** | Middleware — *Handler Context* | Long-lived object passed across a connection; holds `SessionManager` and server state. |
| **context** | Middleware — *Request Context* | Short-lived, per-request mutable state: active session reference, response buffer, server-state snapshot. |
| **context** | Session — *Session* | "Execution context" in conversation; use *session* or *execution namespace* instead. |
| **context** | Bounded Context | DDD term for a coherent vocabulary boundary (this document's top-level structure). |
| **response** | Protocol | A JSON message sent by the server. Can be intermediate (streaming chunk) or terminal. |
| **terminal response** | Protocol | The one response per request that contains `"done"` in `status`. Canonical term; prefer over "done message" or "final response". |
| **state** | Session — *Session State* | Lifecycle enum: `SessionIdle`, `SessionRunning`, `SessionClosed`. |
| **state** | Security — *Server State* | Shared mutable counters: active eval count, active eval task set. |

## Cross-Cutting Rules

These apply across all contexts:

- **Kebab-Case** — all JSON wire keys use hyphens (`new-session`, `timeout-ms`). Never snake_case on the wire.
- **Flat Envelope** — no nested objects in request/response messages; all values are scalars or arrays of scalars.
- **Streaming** — a single request produces one or more response messages before a terminal `done`.
- **FIFO Ordering** — within one session, evaluations execute sequentially in arrival order.
- **Session Isolation** — concurrent sessions cannot observe each other's bindings.
- **Ephemeral vs Persistent** — *ephemeral* means transient, per-request, no identity; *persistent* (named) means UUID-identified, survives across requests.
- **Atomic Transitions** — session state changes are protected by a lock; no partial states are ever visible.
- **Graceful Degradation** — optional dependencies (Revise.jl, Malt.jl) are absent without crashing; behaviour degrades to a safe fallback.
- **Safe Rendering** — exceptions during `repr()` / `show()` are caught and rendered with a fallback; they never propagate to the transport.
