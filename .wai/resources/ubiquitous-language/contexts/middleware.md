# Middleware Context

Scope: the composable handler pipeline that routes operations to their
implementations. Nothing in this context knows about the wire or Julia
execution — it only composes and dispatches.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **Middleware** | Composable unit of request handling. Implements `handle_message(mw, msg, ctx, next)`. Abstract base type: `AbstractMiddleware`. |
| **Middleware Stack** | Ordered, immutable (after startup) vector of middleware instances. Requests traverse it front-to-back. |
| **Middleware Descriptor** | Static metadata declared by each middleware: `provides`, `requires`, `expects`, and `op_info`. Used for stack validation at startup. |
| **Provides** | Set of operation names a middleware claims to handle (e.g., `Set(["eval"])`). No two middleware in a stack may provide the same op. |
| **Requires** | Set of operation names that must be provided by an *earlier* middleware in the stack. Checked at build time. |
| **Expects** | Human-readable ordering constraint string (e.g., `"must appear before EvalMiddleware"`). Informational; used in error messages. |
| **Op Info** | Per-operation metadata map: `doc`, `required_fields`, `optional_fields`, `return_fields`. Exposed via `describe`. |
| **Handler** | The single function produced by `build_handler(stack)`. Signature: `(msg, ctx) → Vector{Dict}`. |
| **Handler Context** | Shared across a connection's lifetime. Holds the `SessionManager` and server state. |
| **Request Context** | Mutable, per-request state: active session reference, emitted responses buffer, server state snapshot. |
| **Response Sink** | The `ctx.emitted` buffer into which middleware pushes intermediate streaming responses. |
| **Next** | Continuation callback passed to each middleware. Calling it delegates to the remainder of the stack (continuation-passing style). |

## Built-in Middleware (ordered)

| Middleware | Provides |
|-----------|----------|
| `SessionMiddleware` | `session` routing for any op requiring a named session |
| `SessionOpsMiddleware` | `clone`, `close`, `ls-sessions` |
| `DescribeMiddleware` | `describe` |
| `InterruptMiddleware` | `interrupt` |
| `StdinMiddleware` | `stdin` |
| `EvalMiddleware` | `eval` |
| `CompleteMiddleware` | `complete` |
| `LookupMiddleware` | `lookup` |
| `LoadFileMiddleware` | `load-file` |
| `UnknownOpMiddleware` | fallback — rejects any op not handled above |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Build Handler** | Compose a stack into a single `handler` function. Validates the stack (duplicates, unsatisfied requires). |
| **Validate Stack** | Check: no duplicate `provides`; all `requires` satisfied; `expects` ordering respected. Fails at startup, not at request time. |
| **Dispatch** | Recursively call `handle_message` starting at index N, passing `next` as the continuation. |
| **Emit Response** | Push an intermediate message into `ctx.emitted`. Used for streaming (stdout/stderr chunks). |
| **Finalize Responses** | Collect `ctx.emitted` + terminal response; ensure exactly one `done` per request. |
| **Handle Message** | Implement this on a concrete middleware. Return `nothing` to pass through to `next`; return a response to short-circuit. |
| **Shutdown Middleware** | On server shutdown, call `shutdown(mw)` in reverse stack order. |

## Design Rules

- **Pass-through** — if a middleware doesn't handle an op, it calls `next` and returns its result unchanged.
- **Short-circuit** — a middleware may return a response without calling `next` to fully own the response.
- **Unknown op fallback** — `UnknownOpMiddleware` is always last; it returns `status: ["done", "error", "unknown-op"]` for any op that reached it.
- **Immutable after startup** — the stack is frozen once `build_handler` is called; no dynamic registration at runtime.
