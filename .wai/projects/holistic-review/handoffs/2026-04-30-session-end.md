---
date: 2026-04-30
project: holistic-review
phase: review
---

# Session Handoff

## What Was Done

<!-- Summary of completed work -->

## Key Decisions

<!-- Decisions made and rationale -->

## Gotchas & Surprises

<!-- What behaved unexpectedly? Non-obvious requirements? Hidden dependencies? -->

## What Took Longer Than Expected

<!-- Steps that needed multiple attempts. Commands that failed before the right one. -->

## Open Questions

<!-- Unresolved questions -->

## Next Steps

<!-- Prioritized list of what to do next -->

## Context

### open_issues

```
○ REPLy_jl-1i8 ● P1 [bug] SEC: Revise hook executes caller-controlled Main.Revise.revise() (H-5)
○ REPLy_jl-2j0 ● P1 [bug] DX: Docs teach unexported symbols as primary API (SessionManager, create_named_session!, EvalMiddleware, SessionMiddleware)
○ REPLy_jl-3a9 ● P1 [bug] SEC: No authentication on TCP eval endpoint (C-1)
○ REPLy_jl-65d ● P1 [bug] perf: replace mktemp IO capture with pipe-based capture in _run_eval_core
○ REPLy_jl-9ms ● P1 [bug] readline() in receive() allocates unbounded memory before size check fires (OOM DoS)
○ REPLy_jl-dxp ● P1 [bug] perf: EVAL_IO_CAPTURE_LOCK serialises all concurrent evals to single-thread throughput
○ REPLy_jl-tox ● P1 [bug] Fix: active_eval_tasks bookkeeping leak on invalid module path (IS-6)
○ REPLy_jl-wep ● P1 [bug] COMP-1: InterruptMiddleware and StdinMiddleware bypass ctx.session, re-resolve from manager with TOCTOU window
○ REPLy_jl-1jy ● P2 [bug] MOD-2: EVAL_IO_CAPTURE_LOCK shared implicitly between eval.jl and load_file.jl via include order
○ REPLy_jl-2r9 ● P2 [bug] DX: status.md capability matrix incorrectly shows Unix sockets as not implemented
○ REPLy_jl-6sr ● P2 [bug] MOD-1: No abstract server handle type; TCPServerHandle/UnixServerHandle/MultiListenerServer shutdown logic duplicated
○ REPLy_jl-8tq ● P2 [bug] DX: mcp_ensure_default_session! docs say it returns name string but it returns UUID
○ REPLy_jl-a28 ● P2 [bug] DX: mcp_new_session_result docs show wrong content format — regex example crashes on real output
○ REPLy_jl-a4o ● P2 [bug] perf: per-eval @async stdin feeder Task + Pipe allocation on named-session hot path
○ REPLy_jl-bxo ● P2 [bug] DX: api.md is an autodoc stub with no prose — unusable without a rendered docs site
○ REPLy_jl-c3z ● P2 [bug] DX: howto-mcp-adapter.md has no end-to-end example — julia_eval/mcp_call_tool split is buried in prose
○ REPLy_jl-cwb ● P2 [bug] EVAL_IO_CAPTURE_LOCK serializes all evals globally, defeating max_concurrent_evals
○ REPLy_jl-dx7 ● P2 [bug] DX: index.md middleware example silently degrades server — replaces full default stack with 2 elements
○ REPLy_jl-e30 ● P2 [bug] perf: invokelatest world-age barrier on every named-session eval even when Revise is absent
○ REPLy_jl-e9g ● P2 [bug] COMP-2: Ephemeral session lifecycle and named-session eval serialization duplicated in eval.jl and load_file.jl
○ REPLy_jl-exj ● P2 [bug] Fix: max_sessions enforcement is non-atomic (MATH-1)
○ REPLy_jl-fyr ● P2 [bug] LoadFileMiddleware, CompleteMiddleware, LookupMiddleware absent from default_middleware_stack
○ REPLy_jl-gfo ● P2 [bug] COMP-6: MCP adapter bypasses SessionOpsMiddleware for session lifecycle, omitting session limit enforcement
○ REPLy_jl-gk2 ● P2 [bug] AuditLog is implemented but record_audit! is never called in production paths
○ REPLy_jl-hdr ● P2 [bug] DX: tutorial-custom-client.md misidentifies JSON3 as a standard library
○ REPLy_jl-it7 ● P2 [bug] DX: howto-mcp-adapter.md never shows how to instantiate a JSONTransport — transport wiring is invisible
○ REPLy_jl-iuq ● P2 [bug] perf: @async timeout task + closure heap allocation per eval (task churn)
○ REPLy_jl-ktf ● P2 [bug] COMP-3: Session limit check copy-pasted three times across session.jl and session_ops.jl
○ REPLy_jl-qr9 ● P2 [bug] clients and client_tasks vectors in TCPServerHandle mutated from multiple tasks without a lock
○ REPLy_jl-r50 ● P2 [bug] DX: howto-sessions.md error response examples omit 'done' flag — clients may loop forever
○ REPLy_jl-xvl ● P2 [bug] max_output_bytes and max_session_history ResourceLimits fields are not enforced at runtime
○ REPLy_jl-y31 ● P2 [bug] perf: receive() materialises JSON3.Object to Dict{String,Any} on every inbound message

--------------------------------------------------------------------------------
Total: 32 issues (32 open, 0 in progress)

Status: ○ open  ◐ in_progress  ● blocked  ✓ closed  ❄ deferred
```
