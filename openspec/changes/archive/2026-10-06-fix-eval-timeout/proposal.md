# Change: Bound client timeout while retaining zombie eval accounting

## Why

A non-interruptible eval (tight `ccall`, BLAS, native code) may ignore `InterruptException`. Waiting for it can violate the reference-hardware 100 ms p99 timeout-response requirement, but releasing its concurrency and session accounting while it remains live permits unbounded native work and unsafe session reuse. The server must meet that response requirement without pretending that an in-process task has been reclaimed.

## What Changes

- Treat manual interrupt as a cancellation request, not a terminal cause: observed task termination produces interrupted completion only if it precedes the deadline; otherwise a still-live task is atomically classified as a zombie and receives exactly one timeout terminal response.
- Retain exactly one EvalGate permit, active-task registration, and session/resource accounting for every live eval until actual termination; completion performs cleanup exactly once.
- Permanently quarantine named sessions that produce zombies. Normal session-targeting operations, `stdin`, best-effort idempotent `interrupt`, and `close` respond within 100 ms p99 on reference hardware without acquiring or waiting on `eval_lock`, EvalGate, or task completion.
- Make `close` atomically remove the session object from discovery without acquiring or waiting on `eval_lock`, EvalGate, or task completion. When the object still has a live task, transition it to `DETACHED`, retain hidden `max_sessions` accounting, and defer object-identity-keyed teardown until termination. When a quarantined object's zombie has already terminated, perform normal teardown and transition directly to `DESTROYED` instead of waiting in `DETACHED` for an already-past event. The freed alias may resolve through an interrupt request's `session` field only to a replacement that old cleanup cannot affect; `interrupt-id` remains an eval ID filter and cannot recover old detached work.
- Keep ephemeral zombies registered and accounted until termination.
- Reject new evals and already queued acquisitions without acquiring or waiting on `eval_lock`, EvalGate, or task completion when live zombies make progress impossible; rejection meets the reference-hardware 100 ms p99 response bound.
- Establish process termination as the only hard reclamation boundary for non-cooperative in-process work.

## Impact

- Affected specs: `security`, `session-management`, `error-handling`
- Affected code: `src/middleware/eval.jl`, `src/middleware/interrupt.jl`, `src/middleware/session.jl`, `src/middleware/session_ops.jl`, `src/config/eval_gate.jl`, `src/config/server_state.jl`, `src/session/manager.jl`, `src/session/module_session.jl`
- Follow-up implementation: `REPLy_jl-kz6c` after proposal approval
