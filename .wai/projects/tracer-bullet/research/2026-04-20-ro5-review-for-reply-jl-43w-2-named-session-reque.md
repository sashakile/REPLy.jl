---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-2, pipeline-step:review]
---

Ro5 review for REPLy_jl-43w.2 (named-session request routing). Verdict: APPROVED. 0 CRITICAL, 0 HIGH, 2 MEDIUM, 1 LOW.

MEDIUM-1 (session.jl:8-16): Named session routing applies to ALL ops, not just eval. A non-eval op (e.g. ls-sessions) with a session key triggers lookup and session-not-found error. This is arguably correct (fail fast on bad session IDs) but the behavior for non-eval ops with valid session keys is to set ctx.session then pass through to the next middleware which ignores it. Should document this routing contract explicitly. No test covers non-eval op + session key.

MEDIUM-2 (session.jl:18-30 vs core.jl:37): Dual ephemeral creation paths. SessionMiddleware creates/destroys ephemeral sessions (lines 23-30), and eval_responses also has ephemeral creation logic (core.jl:37). When SessionMiddleware runs first (which it always does in default stack), eval_responses ephemeral path is dead code. This redundancy is defensive but makes the ownership contract unclear. Consider removing one path and documenting which layer owns ephemeral lifecycle.

LOW-1 (errors.jl:31): session_not_found_response is not exported. Currently only used internally by session middleware, which is fine, but inconsistent with unknown_op_response which is also internal. Minor — no action needed unless public API is planned.
