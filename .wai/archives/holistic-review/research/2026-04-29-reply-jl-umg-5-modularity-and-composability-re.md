---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

# REPLy_jl-umg.5 — Modularity and Composability Review
**Date:** 2026-04-29
**Pass:** REPLy_jl-umg.5
**Skills applied:** modularity-diagnostician, composability-diagnostician, abstraction-miner

---

## Executive Summary

The REPLy.jl architecture shows deliberate layering and a clean abstract middleware protocol. Cohesion within individual files is generally high. The main structural problems are:

1. **Composition friction from a leaky RequestContext** — middleware pieces reach directly into a mutable shared context bag rather than receiving pre-resolved values, creating invisible ordering dependencies.
2. **Two-layer session resolution: partial and repeated** — SessionMiddleware resolves once into `ctx.session`, but several downstream middleware re-resolve or re-validate the session from scratch, creating TOCTOU windows and semantic redundancy.
3. **Duplicated eval execution kernel** — `eval.jl` and `load_file.jl` each contain a full copy of the IO-capture, temp-file, lock-acquire, named-session lifecycle, ephemeral fallback, and error-response assembly pattern.
4. **Server handle structs have no common abstract type** — `TCPServerHandle`, `UnixServerHandle`, and `MultiListenerServer` share no abstract parent despite sharing six of nine fields and identical shutdown semantics.
5. **`default_middleware_stack` is frozen and excludes opt-in middlewares** — `CompleteMiddleware`, `LookupMiddleware`, and `LoadFileMiddleware` are never added to `default_middleware_stack`, making them invisible to MCP stubs and forcing every caller to compose stacks manually.
6. **MCP adapter bypasses the middleware pipeline for session lifecycle** — `mcp_call_tool` calls `SessionManager` directly for `new-session`/`ls-sessions`/`close-session`, duplicating validation logic that already exists in `SessionOpsMiddleware`.

---

## Modularity Findings

### MOD-1 · HIGH — No abstract server-handle type; close/shutdown logic is duplicated verbatim
**Files:** `src/transport/tcp.jl:1-30`, `src/server.jl:97-225`

`TCPServerHandle` and `UnixServerHandle` are structurally identical (listener, port/path, accept_task, client_tasks, clients, handler, middleware, closing, state) and differ only in the listener type and the presence of a path string. `MultiListenerServer` wraps a `Vector` of those two but holds the same `state`, `middleware`, and `closing` fields.

`close_server!` (lines 97-125 of server.jl) is called by both `Base.close(::TCPServerHandle)` and `Base.close(::UnixServerHandle)`, with `UnixServerHandle` adding an `rm` in its finally. `Base.close(::MultiListenerServer)` (lines 182-225) re-implements the entire shutdown sequence — interrupt evals, wait for tasks, close clients, wait for client tasks, shutdown middleware, rm Unix paths — as an expanded loop over `server.listeners`. There is no shared abstract function that a single implementation delegates to.

Consequence: a change to the shutdown protocol (e.g., a new grace logic for eval teardown) must be made in two separate code paths that can drift silently.

Suggested abstraction: an `AbstractServerHandle` abstract type with a `close_server!(::AbstractServerHandle)` default that `MultiListenerServer` delegates to per-listener. The Unix socket cleanup is the only specialization needed.

---

### MOD-2 · HIGH — `EVAL_IO_CAPTURE_LOCK` is a module-level global shared across `eval.jl` and `load_file.jl`
**Files:** `src/middleware/eval.jl:40`, `src/middleware/load_file.jl:87`

The `EVAL_IO_CAPTURE_LOCK` constant is defined in `eval.jl` and used directly in `load_file.jl`. `load_file.jl` has no import or explicit dependency declaration — it relies on Julia's module-flat include order. This is an invisible compile-order coupling; if `load_file.jl` were included before `eval.jl` it would fail at runtime. The lock is a global singleton, meaning load-file evals and eval-middleware evals share the same serialization primitive, which is architecturally correct (they both call `redirect_stdout`) but makes the dependency implicit and undocumented.

Suggested fix: define `EVAL_IO_CAPTURE_LOCK` in a shared `eval_core.jl` (or `src/middleware/core.jl`) and have both `eval.jl` and `load_file.jl` reference it explicitly.

---

### MOD-3 · MEDIUM — `default_middleware_stack` excludes `CompleteMiddleware`, `LookupMiddleware`, `LoadFileMiddleware`
**Files:** `src/middleware/core.jl:134-136`

Three implemented and exported middleware pieces are absent from `default_middleware_stack`. Their `describe` op_info is never collected into the ops catalog when using the default stack. The MCP adapter advertises `julia_complete`, `julia_lookup`, and `julia_load_file` in its tool schema but routes them to `mcp_stub_result("not yet implemented")`. If `CompleteMiddleware` etc. were added to the default stack, `mcp_call_tool` could route through the pipeline instead.

This is a coherence gap between the declared MCP interface and the active middleware stack.

---

### MOD-4 · LOW — `HandlerContext` is a one-field wrapper that adds no abstraction
**File:** `src/middleware/core.jl:76-78`

`HandlerContext` holds only `manager::SessionManager`. It is constructed once per `build_handler` call and its sole use is to copy `manager` into each per-request `RequestContext`. This is mild premature indirection worth watching for accretion.

---

## Composability Findings

### COMP-1 · CRITICAL — Session resolution is split: downstream middleware re-resolve from manager bypassing ctx.session
**Files:** `src/middleware/session.jl`, `src/middleware/interrupt.jl:43-50`, `src/middleware/stdin.jl:44-56`

`SessionMiddleware` resolves `session` field into `ctx.session` for every request carrying a `session` key. However, `InterruptMiddleware.interrupt_responses` re-reads `get(request, "session", nothing)` from the raw message and calls `lookup_named_session(ctx.manager, ...)` directly (line 48), bypassing `ctx.session`. `StdinMiddleware.stdin_responses` does the same (line 54). Both then do their own incomplete validation (`isempty` only, not the full regex).

This means:
- If a session is destroyed between `SessionMiddleware` resolution and the second lookup, these middleware return session-not-found even though the middleware contract says the session is already resolved.
- The `validate_session_name` in `SessionMiddleware` is silently bypassed; `interrupt` and `stdin` do their own weaker check.
- Composition is not idempotent: adding `SessionMiddleware` to the stack does not guarantee downstream middleware will use `ctx.session`.

Suggested fix: `InterruptMiddleware` and `StdinMiddleware` should consume `ctx.session` (a `NamedSession` when `SessionMiddleware` ran) instead of re-resolving. A guard on the type covers pipelines without `SessionMiddleware`.

---

### COMP-2 · HIGH — Ephemeral session lifecycle and named-session eval serialization duplicated in `eval.jl` and `load_file.jl`
**Files:** `src/middleware/eval.jl:248-253,303-337,388`, `src/middleware/load_file.jl:60-61,65-79,78`

The ephemeral-fallback pattern:
```
ephemeral = isnothing(ctx.session) ? create_ephemeral_session!(ctx.manager) : nothing
session = something(ephemeral, ctx.session)
try ... finally !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral) end
```
and the named-session serialization pattern:
```
lock(session.eval_lock) do
    try_begin_eval!(session, current_task()) || return [error_response(...)]
    try _run_*_core(...) finally end_eval!(session) end
end
```
are both copy-pasted verbatim across the two files. Any change to the locking discipline must be replicated.

Suggested abstraction: a `with_session_eval(ctx, request_id, session; f::Function) -> Vector{Dict}` helper that accepts a callback. Both `eval.jl` and `load_file.jl` reduce to their core logic.

---

### COMP-3 · HIGH — Session limit check block copy-pasted in three places
**Files:** `src/middleware/session.jl:53-58`, `src/middleware/session_ops.jl:100-103`, `src/middleware/session_ops.jl:225-228`

The identical block:
```julia
if !isnothing(ctx.server_state) &&
        total_session_count(ctx.manager) >= ctx.server_state.limits.max_sessions
    return [error_response(request_id, "Session limit reached";
                status_flags=String["error", "session-limit-reached"])]
end
```
is repeated three times across two files. Any change to the error message, status flags, or limit semantics must be replicated.

Suggested abstraction: `check_session_limit(ctx, request_id) -> Union{Nothing, Vector{Dict}}`.

---

### COMP-4 · MEDIUM — `RequestContext` is a mutable context bag; `emit!` and `ctx.emitted` are dead code
**File:** `src/middleware/core.jl:89-99`

`RequestContext` is `mutable struct` and middleware writes to `ctx.session` directly. The `emitted` field and `emit!` function exist but no middleware calls `emit!` — all middleware return responses directly. `finalize_responses` calls `vcat(ctx.emitted, terminal)` but `ctx.emitted` is always empty, making this a dead accumulation path that adds surface area to the context contract.

---

### COMP-5 · MEDIUM — `materialize_middleware_stack` is hardcoded to `DescribeMiddleware`; called twice by `serve`
**File:** `src/middleware/core.jl:138-145`, `src/server.jl:37-38`

The replacement inside `materialize_middleware_stack` is hardcoded by type name (`mw isa DescribeMiddleware`). Any future middleware needing a "materialized" form has no clean participation mechanism. Additionally, `serve` calls `materialize_middleware_stack` at line 37 and then passes the result to `build_handler` at line 38, which calls `materialize_middleware_stack` again internally — resulting in a redundant double-materialization pass.

---

### COMP-6 · HIGH — MCP adapter bypasses `SessionOpsMiddleware`, omitting session limit enforcement
**File:** `src/mcp_adapter.jl:217-241`

`mcp_call_tool` calls `SessionManager` functions directly for session creation, listing, and closing, bypassing `SessionOpsMiddleware`. The session limit check present in `SessionOpsMiddleware` (line 100-103) is not called when `julia_new_session` is routed through the MCP adapter. This is a functional divergence: the limit can be exceeded via MCP but not via the direct protocol.

---

## Abstraction Miner Findings

### ABS-1 — Missed endomorphism: `with_named_session_eval`
Both `eval_responses` and `load_file_responses` implement the full named-session eval lifecycle (see COMP-2). A `with_session_eval` wrapper function eliminates the duplication.

### ABS-2 — Missed abstraction: `check_session_limit` guard function
Three identical inline limit-check blocks (see COMP-3). Single predicate function eliminates repetition.

### ABS-3 — Missed abstraction: abstract server handle with shared shutdown
`TCPServerHandle` and `UnixServerHandle` share six of nine fields and identical shutdown semantics (see MOD-1). An `AbstractServerHandle` parent type with a default `close_server!` implementation collapses the duplication.

### ABS-4 — Missed endomorphism: `resolve_required_session`
Both `interrupt_responses` and `stdin_responses` implement the same extract-validate-lookup-not-found pattern (see COMP-1). A `resolve_required_session(ctx, request, request_id) -> Union{NamedSession, Vector{Dict}}` helper DRYs the pattern and fixes the TOCTOU issue simultaneously.

### ABS-5 — Semantic duplication: MCP tool schema and middleware `op_info` diverging
Every op has two schema descriptions: one in the middleware `op_info` dictionary and one in `mcp_tools()`. Already drifted: `mcp_tools()` uses `"interrupt_id"` (snake_case) while the protocol field is `"interrupt-id"` (kebab-case, `src/middleware/interrupt.jl:53`). A single source-of-truth for op schemas would eliminate this class of drift.

---

## Architecture Assessment by Seam

| Seam | Cohesion | Coupling | Friction | Notes |
|------|----------|----------|----------|-------|
| Protocol (message.jl) | High | Low | Low | Clean transport abstraction |
| Middleware core (core.jl) | High | Medium | Medium | RequestContext mutable bag is main friction |
| Session middleware (session.jl) | High | Medium | Medium | Elegant but downstream bypass it |
| Session ops middleware (session_ops.jl) | Medium | High | High | Two-layer resolution, inline limit checks, compat alias sprawl |
| Eval middleware (eval.jl) | Medium | High | High | 415 lines; shares hidden lock with load_file.jl |
| Load-file middleware (load_file.jl) | Medium | High | Medium | Duplicates eval lifecycle; implicit lock dependency |
| Transport/TCP (tcp.jl) | High | Low | Low | Handle structs should share abstract type |
| Server (server.jl) | Medium | Medium | High | serve/serve_multi duplicate listener creation; double-materialization |
| Session layer (manager.jl, module_session.jl) | High | Low | Low | Well-structured; three-phase sweep correct |
| MCP adapter (mcp_adapter.jl) | Medium | High | High | Bypasses middleware; omits session limit; snake/kebab mismatch |

---

## Summary of Critical and High Findings

| ID | Severity | Finding |
|----|----------|---------|
| COMP-1 | Critical | InterruptMiddleware and StdinMiddleware re-resolve sessions from manager, bypassing ctx.session; TOCTOU window |
| MOD-1 | High | No abstract server handle; shutdown logic duplicated across TCPServerHandle/UnixServerHandle/MultiListenerServer |
| MOD-2 | High | EVAL_IO_CAPTURE_LOCK shared implicitly between eval.jl and load_file.jl via include order |
| COMP-2 | High | Ephemeral session lifecycle and named-session eval serialization duplicated verbatim in eval.jl and load_file.jl |
| COMP-3 | High | Session limit check block copy-pasted three times across session.jl and session_ops.jl |
| COMP-6 | High | MCP adapter bypasses SessionOpsMiddleware; julia_new_session omits session limit enforcement |
| MOD-3 | Medium | default_middleware_stack excludes CompleteMiddleware, LookupMiddleware, LoadFileMiddleware |
| COMP-4 | Medium | RequestContext mutable bag; emit! and ctx.emitted are dead code |
| COMP-5 | Medium | materialize_middleware_stack hardcoded to DescribeMiddleware; serve double-materializes |
| ABS-5 | Medium | MCP tool schema and middleware op_info diverging; interrupt_id vs interrupt-id already wrong |
