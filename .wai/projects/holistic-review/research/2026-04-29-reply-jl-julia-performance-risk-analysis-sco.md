---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

# REPLy.jl Julia Performance Risk Analysis

## Scope

Files reviewed: src/middleware/eval.jl, src/transport/tcp.jl, src/server.jl, src/mcp_adapter.jl, src/protocol/message.jl, src/session/manager.jl, src/session/module_session.jl, src/config/server_state.jl, src/errors.jl, src/middleware/core.jl, src/middleware/session.jl

No benchmark or profiling files found in the repository.

All findings are **static suspicion** unless labelled otherwise.

---

## CRITICAL Findings

### C-1: Filesystem I/O per eval via mktemp (src/middleware/eval.jl:70-71)

Every single eval call creates two temporary files on disk via `mktemp()`, uses them as I/O capture buffers, then closes and deletes them. This is a filesystem round-trip on every eval hot-path. The pair of `mktemp()` calls involves kernel syscalls (open, fstat, unlink) on the critical path.

**Impact**: High allocation + syscall overhead on every eval. For a REPL server used interactively or at high throughput (up to 10 concurrent evals), this introduces unbounded filesystem latency. On Linux tmpfs this may be fast, but it is still heavier than using an in-memory pipe.

**Alternative**: Replace with pipe-based capture. Note: `redirect_stdout` and `redirect_stderr` require an `IOStream` backed by a file descriptor, so a direct IOBuffer swap is non-trivial. A `Base.Pipe` (already used for stdin capture) may be the right path.

**Evidence**: Static analysis. The overhead is proportional to eval frequency.

---

### C-2: Global process-wide IO capture lock serialises all concurrent evals (src/middleware/eval.jl:40, 74)

The `EVAL_IO_CAPTURE_LOCK` covers the entire eval body including `Core.eval()`. The comment acknowledges `redirect_stdout(IOStream)` uses `dup2` (process-global fd replacement). This means ALL concurrent evals must serialize through a single lock for their full duration. The `max_concurrent_evals` limit is 10, but actual concurrency on the eval path is effectively 1.

**Impact**: Critical throughput bottleneck. Multi-threaded Julia runtimes with multiple client connections get no parallelism on eval. The lock duration includes `Core.eval()`, which can be arbitrarily long.

**Evidence**: Static analysis. The comment in the code acknowledges the `dup2` issue. The lock scope comment on line 99 confirms the lock is held across the full eval.

---

## HIGH Findings

### H-1: @async Task allocation per eval for timeout (src/middleware/eval.jl:277)

A new `Task` is spawned via `@async` for every eval that has a timeout configured. The `timedwait` inside polls every 50ms for the lifetime of the eval. The closure captures `ch`, `eval_task`, `timed_out`, `effective_timeout_ms` — all heap allocations due to closure boxing.

**Impact**: Task churn and polling overhead proportional to eval rate. The default timeout is 30,000ms; at 10 concurrent evals, up to 10 polling tasks run simultaneously.

**Evidence**: Static analysis.

### H-2: @async Task and Pipe allocation per named-session eval for stdin feeder (src/middleware/eval.jl:317)

A new `Task` and `Base.Pipe` are created for every named-session eval when `allow_stdin=true` (the default). The `Pipe` allocation includes two libuv handles.

**Impact**: Steady per-eval heap allocation (Pipe + Task + closure). High task churn under interactive use.

**Evidence**: Static analysis.

### H-3: Dict{String,Any} allocations throughout hot path (eval.jl, message.jl, mcp_adapter.jl)

Every response message is a `Dict{String,Any}`. On the eval success path, at minimum 3 dicts are created per eval. The `map` calls in `eval_responses` (lines 364-379) create new intermediate arrays even when the identity transformation applies.

**Impact**: Moderate allocation pressure per request; accumulates under sustained load.

**Evidence**: Static analysis.

### H-4: receive() calls readline() then allocates Dict per message (src/protocol/message.jl:31-51)

`readline` allocates a `String` for the full line. `JSON3.read` returns a lazy `JSON3.Object` but the final conversion to `Dict{String, Any}` via a generator comprehension copies every key-value pair. The source comment explicitly acknowledges this allocation behaviour.

**Impact**: Two heap allocations per message (String + Dict) in addition to JSON3 parse under high message rates.

**Evidence**: Static analysis + source comment on line 22.

### H-5: World-age latency on every named-session eval via invokelatest (src/middleware/eval.jl:197)

`Base.invokelatest(_revise_if_present)` adds a world-age barrier on every named-session eval, even when Revise is not loaded. The world-age check cost is paid before the `isdefined(Main, :Revise)` guard can short-circuit.

**Impact**: Constant overhead per named-session eval when `revise_hook_enabled=true` (the default). For short evals (e.g., expression lookups), this overhead is a non-trivial fraction of total latency.

**Evidence**: Static analysis. Mitigated if the server is started with `revise_hook_enabled=false`.

---

## MEDIUM Findings

### M-1: Variadic Pair... in response_message causes splatting allocations (src/protocol/message.jl:64)

The `response_message` function uses `pairs::Pair...` variadic arguments, which are heap-allocated as a tuple when called with non-constant argument counts on the hot path.

### M-2: stacktrace_payload allocates a Vector{Dict} on every error (src/errors.jl:42-50)

`stacktrace(bt)` itself allocates (symbol resolution). Only on the error path, but can cause latency spikes during iterative development where user code frequently throws.

### M-3: filter! O(n) scans on client/task vectors in accept_loop! (src/transport/tcp.jl:124-125)

Two `filter!` calls run inside per-client cleanup task on disconnect, scanning full `clients` and `client_tasks` vectors linearly. The vectors are unsynchronized (no lock guards these reads), which is a latent data race under multi-threaded Julia.

### M-4: clamp_history! uses deleteat! which shifts the entire history vector (src/session/module_session.jl:84-86)

`deleteat!(session.history, 1:excess)` shifts all remaining elements left — O(n) memory moves per clamp. For the default MAX_SESSION_HISTORY_SIZE=1000, this is at most 1000 pointer moves per 1000th eval — low severity in practice.

### M-5: collect_reply_stream spawns a Task and uses timedwait polling (src/mcp_adapter.jl:262)

Similar to H-1: a Task is spawned and the caller blocks on `timedwait`. The `collected` vector grows with `push!` and may trigger multiple resizings for long eval sessions.

### M-6: popfirst! on buffered message vectors (src/mcp_adapter.jl:268)

`popfirst!` on a `Vector` is O(n). In the typical single-request case this is trivial, but for interleaved streams it can cause repeated linear shifts.

---

## Type Instability Suspicions

### T-1: result is Union{Vector, Tuple} in _run_eval_core (src/middleware/eval.jl:107)

The `result` variable assigned from inside `lock(EVAL_IO_CAPTURE_LOCK) do...end` can be either `Vector{Dict{String,Any}}` (error path) or `Tuple{Any,String,String}` (success path). Julia cannot infer a concrete return type for the lock closure and will likely infer `Any` or a wide union.

### T-2: ctx.session is Union{ModuleSession, NamedSession, Nothing} (src/middleware/core.jl:90-93)

All session-consuming code must branch on `session isa NamedSession` after retrieving `ctx.session`. This unavoidable union type on a hot-path field forces runtime type checks at every session access point.

### T-3: history::Vector{Any} in NamedSession (src/session/module_session.jl:67)

Reads from the history vector require dynamic dispatch for any operation on elements. Low severity as history is rarely read in the hot path.

---

## Dynamic Dispatch Suspicions

### D-1: AbstractMiddleware dispatch in dispatch_middleware (src/middleware/core.jl:111-115)

`handle_message` dispatch is virtual through abstract type `AbstractMiddleware`. For a 7-element stack, each request passes through 7 dynamic dispatches. The `next` closure captures `stack`, `index`, and `ctx` — heap allocated on every recursion level. The `Vector{AbstractMiddleware}` type annotation prevents devirtualization.

### D-2: Function field handler::Function in TCPServerHandle (src/transport/tcp.jl:7)

`Function` is an abstract type. The `handle.handler(msg)` call in `handle_client!` is a dynamic dispatch on an abstract field type — Julia cannot specialize the inner receive loop body on the concrete handler type.

---

## Serialization/Deserialization Overhead

### S-1: JSON3 parse then immediate Dict copy per message

The receive path uses JSON3 (lazy parser) but immediately materialises to `Dict{String,Any}`. Keeping the `JSON3.Object` representation would avoid this copy but would require type annotation changes throughout the middleware stack.

### S-2: JSON3.write + flush per send under transport lock (src/protocol/message.jl:13-17)

`JSON3.write` allocates a String buffer. The `flush` call on every message is a syscall. For high-throughput scenarios, batching writes and deferring flush would reduce syscall frequency.

---

## Candidate Benchmarks / Profiling Probes

1. **mktemp vs pipe**: Microbenchmark `_run_eval_core` with `1+1` to measure wall time. Compare with a pipe-based implementation.
2. **Eval throughput under EVAL_IO_CAPTURE_LOCK**: Spawn N tasks each calling `eval_responses` with a trivial expression; measure actual throughput vs. N.
3. **dispatch_middleware allocation profile**: `@allocated dispatch_middleware(stack, 1, msg, ctx)` — baseline: 7 `next` closures expected.
4. **receive() allocation profile**: `@allocated receive(transport)` — baseline: 1 String + 1 Dict. Compare against JSON3.Object-preserving path.
5. **invokelatest overhead**: Profile `_maybe_revise!` with Revise not loaded to measure world-age barrier cost alone.
6. **Timer task count under load**: Verify `@async timedwait` tasks accumulate with `Base.tasks()` under sustained eval load.
7. **Profile with Profile.@profile + ProfileView**: 1000 trivial evals in a loop, capturing allocation sites with `--track-allocation`.

---

## Summary Table

| ID | Severity | Category | Location | Evidence |
|----|----------|----------|----------|----------|
| C-1 | Critical | Filesystem I/O | eval.jl:70-71 | Static |
| C-2 | Critical | Lock contention | eval.jl:40,74 | Static |
| H-1 | High | Task churn | eval.jl:277 | Static |
| H-2 | High | Task churn | eval.jl:317 | Static |
| H-3 | High | Allocation | eval.jl, message.jl | Static |
| H-4 | High | Alloc/deser | message.jl:31-51 | Static |
| H-5 | High | World-age | eval.jl:197 | Static |
| M-1 | Medium | Allocation | message.jl:64 | Static |
| M-2 | Medium | Allocation | errors.jl:42 | Static |
| M-3 | Medium | O(n) + data race | tcp.jl:124 | Static |
| M-4 | Medium | O(n) shift | module_session.jl:84 | Static |
| M-5 | Medium | Task churn | mcp_adapter.jl:262 | Static |
| M-6 | Medium | O(n) shift | mcp_adapter.jl:268 | Static |
| T-1 | Medium | Type instab. | eval.jl:107 | Static |
| T-2 | Medium | Type instab. | core.jl:90 | Static |
| T-3 | Low | Type instab. | module_session.jl:67 | Static |
| D-1 | Medium | Dyn. dispatch | core.jl:111 | Static |
| D-2 | Medium | Dyn. dispatch | tcp.jl:7 | Static |
| S-1 | Medium | Deser overhead | message.jl:51 | Static |
| S-2 | Medium | Ser overhead | message.jl:13 | Static |
