---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

# REPLy.jl — Rule of 5 Whole-Codebase Review
**Pass:** REPLy_jl-umg.4 — Broad whole-codebase review using Rule of 5
**Date:** 2026-04-29

---

## Executive Summary

REPLy.jl is a well-structured Julia REPL-over-TCP server with clear layering
(transport → protocol → middleware → session → security). The codebase shows
deliberate concurrency design: documented lock ordering, three-phase TOCTOU-safe
sweep, and atomic counters. However, several significant correctness gaps and
security risks remain, most tracing to a single root cause: **resource limits
were added as configuration fields but enforcement was deferred**, leaving real
attack surface exposed to uncontrolled memory growth.

---

## Pass 1 — Correctness

### C1 · CRITICAL — `readline()` allocates attacker-controlled memory before the size check
**File:** `src/protocol/message.jl:23-40`

The comment explicitly documents this: `readline()` buffers the full message in
memory before the size check fires. A client can exhaust JVM heap with a single
50 GiB newline-free stream. The `max_message_bytes` guard fires only *after* the
OS has already allocated the buffer. This is an OOM DoS.

### C2 · HIGH — `max_output_bytes` and `max_session_history` limits silently ignored
**File:** `src/config/resource_limits.jl:12-13`

Both `ResourceLimits.max_output_bytes` and `ResourceLimits.max_session_history`
are documented as "Enforcement deferred". A user-visible `sleep(0)` loop writing
to stdout can fill an unbounded `IOBuffer` backed by mktemp; a persistent session
running many evals accumulates `session.history` up to 1000 items, but the
`clamp_history!` function reads `MAX_SESSION_HISTORY_SIZE` (a constant) rather
than `session.limits.max_session_history` — making the per-server config field
a no-op.

### C3 · HIGH — `EVAL_IO_CAPTURE_LOCK` serializes all evals globally
**File:** `src/middleware/eval.jl:40, 74`

The IO capture lock is module-level and held during the entire `redirect_stdout`
+ eval execution. This means all concurrent evals across all sessions are actually
serialized, not just IO-isolated. The `max_concurrent_evals` limit is enforced
before this lock is acquired, creating a second-level bottleneck that silently
undoes the concurrency guarantee the config promises.

### C4 · MEDIUM — `close` op performs a second `lookup_named_session` after SessionMiddleware already resolved it
**File:** `src/middleware/session_ops.jl:168`

`handle_close_session` calls `lookup_named_session(ctx.manager, identifier)` even
when `ctx.session` is already populated by `SessionMiddleware`. Between the
middleware resolution and this second lookup, a concurrent `destroy_named_session!`
could remove the session, causing a spurious `session-not-found` error for an op
that started with a valid session. The destroy-by-UUID path at line 174 is correct
but the intermediate lookup is raceable.

### C5 · MEDIUM — `clone_named_session!` registers dest in the dict before binding copy completes
**File:** `src/session/manager.jl:308-344`

The destination `NamedSession` is inserted into `manager.named_sessions` inside
`lock(manager.lock)`, but the actual binding copy loop runs *outside* the lock
(by design, to avoid holding the lock). This means another task can look up the
new session by name, find it, and begin an eval — in an empty module — before
bindings from the source are populated. A partial-clone invariant violation.

### C6 · MEDIUM — Timeout timer task is unjoined on success path
**File:** `src/middleware/eval.jl:276-290`

The timer `@async` task is cancelled by a `put!(cancel_ch, nothing)` signal, but
the task is never `wait()`-ed. If the timer wakes up just after `cancel_ch` is
signalled but before it checks `isready(ch)` (the TOCTOU window in the timer body
at line 283), it may still fire `schedule(eval_task, InterruptException())` to a
task that has already completed — which Julia's scheduler silently ignores but
wastes resources and could interact poorly with follow-on evals.

### C7 · LOW — `validate_stack` is never called automatically
**File:** `src/middleware/core.jl:39-40`, `src/server.jl:37-38`

`build_handler` and `serve` both call `materialize_middleware_stack` but not
`validate_stack`. A misconfigured custom stack (duplicate ops, missing deps) will
silently produce wrong behavior at runtime with no startup diagnostic.

---

## Pass 2 — Maintainability

### M1 · HIGH — Shared mutable `clients` and `client_tasks` vectors with no lock
**File:** `src/transport/tcp.jl:5-18, 115-127`

`TCPServerHandle.clients` and `client_tasks` are plain `Vector` fields mutated
from both the accept loop task and the finalizer `@async` task (via `filter!`).
Julia's `Vector` is not thread-safe. The accept loop pushes while the client task
pops via `filter!`. Under multi-threading this is a data race; under cooperative
scheduling it is fragile because `filter!` reallocates the vector in place while
another `push!` or `copy` may be reading it.

### M2 · HIGH — `LoadFileMiddleware` not included in `default_middleware_stack`
**File:** `src/middleware/core.jl:134-136`

`LoadFileMiddleware`, `CompleteMiddleware`, and `LookupMiddleware` are fully
implemented and tested, but the default stack (`default_middleware_stack()`) only
includes `SessionMiddleware`, `SessionOpsMiddleware`, `DescribeMiddleware`,
`InterruptMiddleware`, `StdinMiddleware`, `EvalMiddleware`, and
`UnknownOpMiddleware`. Any user relying on `serve()` with defaults cannot access
`load-file`, `complete`, or `lookup` without constructing a custom stack — a
silent capability gap.

### M3 · MEDIUM — Dual counters for active evals: `Atomic{Int}` and `IdDict{Task}`
**File:** `src/config/server_state.jl`

`ServerState` maintains both `active_evals::Threads.Atomic{Int}` and
`active_eval_tasks::IdDict{Task, Nothing}`, incremented and decremented in
`eval_responses` at separate callsites. If one update succeeds and the other
throws (unlikely but possible under OOM), the two counters diverge. A single
`IdDict` and deriving the count from its length would eliminate the dual-bookkeeping risk.

### M4 · MEDIUM — Deprecated op aliases require ongoing maintenance load
**File:** `src/middleware/session_ops.jl:76-84`

`close-session` and `clone-session` emit `@warn` at runtime. There is no mechanism
to remove them or track callers. The deprecation warnings go to stderr of the
server process, which may be unmonitored. There is no test for the "consumer sees
the deprecation warning and migrates" path.

### M5 · LOW — `_update_history!` bypasses `ResourceLimits.max_session_history`
**File:** `src/middleware/eval.jl:396-409`

`clamp_history!` uses the module-level `MAX_SESSION_HISTORY_SIZE` constant, not
the per-server configured limit. This is a coherence gap: the field exists in
`ResourceLimits` and is documented, but changing it via `ResourceLimits(max_session_history=50)` has zero effect.

---

## Pass 3 — Readability

### R1 · MEDIUM — `eval_responses` function is 180+ lines with multiple nested lock scopes
**File:** `src/middleware/eval.jl:204-394`

The function handles: validation, concurrent eval counting, ephemeral session
fallback, module routing, timeout setup, eval_lock acquisition, stdin pipe setup,
feeder task management, Revise hook, IO capture, response construction, eval-id
annotation, and cleanup. Each concern is commented but the nesting depth (5+ levels)
makes control flow hard to follow, especially the error paths.

### R2 · MEDIUM — `RequestContext` carries `session::Union{ModuleSession, NamedSession, Nothing}`
**File:** `src/middleware/core.jl:89-94`

This union means every middleware that uses `ctx.session` must dispatch on the
concrete type. The `load_file.jl` and `eval.jl` do this correctly but the pattern
is implicit. A named type or interface would make the branching explicit and
enforceable by the type system.

### R3 · LOW — `safe_request_id` and `request_id = String(request["id"])` co-exist
**File:** `src/transport/tcp.jl:34`, `src/middleware/eval.jl:205`

`safe_request_id(msg)` is used at the transport level (may get `""` on missing/non-string id), while middleware functions call `String(request["id"])` directly (would throw if id is not a string — but `validate_request` has already run by then). The two idioms are correct but inconsistent; a reader must understand the call chain to verify safety.

### R4 · LOW — `_resolve_lookup_module` uses `Core.eval(Main, Meta.parse(...))` for module resolution
**File:** `src/middleware/lookup.jl:56-64`

Parsing and evaluating an arbitrary user-supplied string (`module_name`) via
`Meta.parse` + `Core.eval` in `Main` scope silently swallows exceptions. Any
failure returns `Main` as fallback — indistinguishable from a valid lookup in
`Main`. The function should return `nothing` on parse/eval failure and let the
caller surface an error.

---

## Pass 4 — Risk

### K1 · CRITICAL — `load-file` reads arbitrary filesystem paths by default
**File:** `src/middleware/load_file.jl:46-50`

`load_file_allowlist` defaults to `nothing`. When `LoadFileMiddleware` is not in
the default stack this is not currently exploitable via `serve()`, but it is
documented and exported, so any user who adds it without an allowlist exposes
unrestricted filesystem read + eval to any TCP client. There is no secure-by-default
wrapper and no README warning.

### K2 · CRITICAL — `lookup` middleware executes user-supplied strings via `Meta.parse` + `Core.eval`
**File:** `src/middleware/lookup.jl:68`

`_lookup_symbol` calls `Core.eval(module_, Meta.parse(symbol_str))`. A client
sending `symbol_str = "run(\`rm -rf /\`)"` executes arbitrary Julia code in the
server process. The function is protected only by a `try/catch` that silently
returns `found => false`. This is a remote code execution vector whenever
`LookupMiddleware` is active.

### K3 · HIGH — Unix socket cleanup on crash leaves stale socket file
**File:** `src/transport/tcp.jl:133-151`, `src/server.jl:131-138`

The `listen_unix` function removes an existing socket path before creating the
new one. The cleanup of the new path after `close(server)` is in
`Base.close(server::UnixServerHandle)`. If the process is `SIGKILL`-ed, the
socket file is never removed and the next startup `listen_unix` call silently
overwrites it — which is fine. However, `ispath(server.path) && rm(server.path)`
in `close` is not atomic: a race between two server processes starting and stopping
simultaneously (e.g., in parallel test suites) can delete the live socket of the
second server.

### K4 · HIGH — `audit.jl` is fully implemented but never wired into any middleware or server path
**File:** `src/security/audit.jl`

`AuditLog` and `record_audit!` are exported and tested in isolation, but no
production code path calls `record_audit!`. The audit module is security theater
as-is: it exists, compiles, has tests — but logs nothing. If audit requirements
ever become contractual, this gap would only surface after a review.

### K5 · MEDIUM — Rate limiting uses a fixed 60-second sliding window with no persistence
**File:** `src/transport/tcp.jl:44-79`

The rate limiter resets on the calendar minute boundary (`now - rl_window_start >= 60`),
which is a tumbling window, not a true sliding window. A client can send
`rate_limit_per_min` requests just before the reset and another `rate_limit_per_min`
immediately after — doubling the effective burst rate. The comment says "sliding
60-second window" but the implementation is a tumbling window.

### K6 · MEDIUM — `receive()` treats malformed JSON as a closed connection
**File:** `src/protocol/message.jl:43-47`

Malformed JSON silently returns `nothing`, which causes `handle_client!` to exit
(line 61: `isnothing(msg) && return nothing`). A client that sends invalid JSON
gets silently dropped without an error response. This is hard to diagnose and may
mask protocol bugs during development.

---

## Pass 5 — Synthesis

### Root Cause A: "Enforcement deferred" — the dominant systemic failure

Four distinct findings (C1, C2, M2, K4) share the same root cause: resource limits,
capabilities, and security controls were **specified and implemented as data
structures** but enforcement was **intentionally deferred** with comments like
"Enforcement deferred" and "not yet implemented (CORR-005)". This pattern creates
false confidence: the configuration surface makes it appear limits exist (e.g.,
`max_output_bytes=1_000_000`) when the runtime enforces nothing.

The risk is compounded because:
- Users reading `ResourceLimits` documentation will configure these fields, believing them active.
- The audit module follows the same pattern: fully implemented, never called.

**Recommendation:** File a single "enforcement gap" ticket tracking C2, M2, and K4 together. C1 (readline OOM) needs its own ticket as it requires a streaming reader.

### Root Cause B: Security-by-opt-in instead of secure-by-default

K1 (`load-file` with no allowlist) and K2 (`lookup` executes arbitrary code) both
arise from the same design decision: dangerous capabilities were implemented as
middleware components without secure-by-default wrappers, and they are not in
`default_middleware_stack()`. This is partly intentional (M2 confirms
`LoadFileMiddleware` is opt-in) but the **risk disclosure surface** is inadequate:
no README warning, no safe constructor, no runtime warning when these middleware
are added.

**Recommendation:** These two should each have a bug/security ticket with clear
remediation: `LookupMiddleware._lookup_symbol` must not use `Core.eval` on
user input; `LoadFileMiddleware` must default to a restrictive allowlist or be
removed from the exported API until a safe default is established.

### Root Cause C: Shared mutable vectors without lock discipline

C4 (double lookup race in close), C5 (partial clone), M1 (unguarded client
vectors) all arise from the same pattern: some shared state is protected by locks
while adjacent state of similar structure is not. The `clients`/`client_tasks`
vectors in `TCPServerHandle` stand out because they live next to a
`closing::Base.RefValue{Bool}` (itself a safe atomic pattern) but have no lock.

---

## Top-Level Risk Register

| # | Severity | Finding | File(s) |
|---|----------|---------|---------|
| 1 | CRITICAL | `readline()` allocates unbounded memory before size check fires (OOM DoS) | `src/protocol/message.jl` |
| 2 | CRITICAL | `LookupMiddleware._lookup_symbol` executes user input via `Core.eval` (RCE) | `src/middleware/lookup.jl` |
| 3 | HIGH | `max_output_bytes` and `max_session_history` limits silently not enforced | `src/config/resource_limits.jl`, `src/middleware/eval.jl` |
| 4 | HIGH | `EVAL_IO_CAPTURE_LOCK` serializes all evals globally, defeating concurrency | `src/middleware/eval.jl` |
| 5 | HIGH | `AuditLog` wired to nothing — no production code calls `record_audit!` | `src/security/audit.jl` |
| 6 | HIGH | `clients`/`client_tasks` vectors mutated from multiple tasks without a lock | `src/transport/tcp.jl` |
| 7 | HIGH | `LoadFileMiddleware` and friends missing from `default_middleware_stack` | `src/middleware/core.jl` |
| 8 | MEDIUM | `clone_named_session!` registers dest before bindings copied (partial clone window) | `src/session/manager.jl` |
| 9 | MEDIUM | Rate limiter is a tumbling window, not a sliding window as documented | `src/transport/tcp.jl` |
| 10 | MEDIUM | Malformed JSON silently drops connection with no error response to client | `src/protocol/message.jl` |

---

## Most Review-Sensitive Files

1. **`src/middleware/eval.jl`** — Highest complexity, central to all eval paths, carries 3 distinct findings (C3, C6, M1 indirect). Any change here is high-blast-radius.
2. **`src/session/manager.jl`** — Complex lock ordering, three-phase sweep, clone gap. Concurrency correctness is subtle.
3. **`src/transport/tcp.jl`** — The accept loop, client vector management, rate limiting, and Unix socket lifecycle all live here without lock protection for the vectors.
4. **`src/middleware/lookup.jl`** — Short but contains the `Core.eval(user_input)` RCE.
5. **`src/protocol/message.jl`** — OOM vulnerability in `receive()`.

---

## Candidate Areas for Follow-Up Specialization

- **Streaming receive** — Replacing `readline()` with a bounded streaming reader (specialist: `julia-performance-diagnostician` or custom reader design)
- **Concurrency audit** — Formal review of all lock sites, especially M1 (client vectors) and the eval_lock / manager.lock ordering in edge cases (`composability-diagnostician`, `mutability-diagnostician`)
- **Security hardening** — `LookupMiddleware` RCE and `LoadFileMiddleware` opt-in risk surface (`red-team-review`)
- **Enforcement gap closure** — Wire `max_output_bytes`, `max_session_history`, and `AuditLog` into actual runtime paths (`test-friction` to confirm test coverage after wiring)
- **MCP adapter completeness** — `julia_complete`, `julia_lookup`, `julia_load_file`, `julia_interrupt` are all stub-returning; the adapter surface is substantially incomplete (`specification-evaluation-diagnostician`)
