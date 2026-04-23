# ResourceLimits — per-request and per-session resource limit configuration.
# All fields have safe defaults suitable for interactive REPL use.

"""
    ResourceLimits(; max_repr_bytes, max_eval_time_ms, max_output_bytes, max_session_history, max_sessions, max_concurrent_evals, rate_limit_per_min)

Immutable configuration struct for resource limits applied to eval requests and sessions.

Fields:
- `max_repr_bytes::Int` — maximum byte length for `repr` output (default: `DEFAULT_MAX_REPR_BYTES`, 10 KB). Active: used by `EvalMiddleware`.
- `max_eval_time_ms::Int` — maximum wall-clock eval time in milliseconds (default: 30 000). Enforced by `EvalMiddleware` (Phase 7C).
- `max_output_bytes::Int` — maximum captured stdout/stderr bytes per eval (default: 1 000 000). Enforcement deferred.
- `max_session_history::Int` — maximum entries in a named session's history vector (default: `MAX_SESSION_HISTORY_SIZE`, 1000). Enforcement deferred; `clamp_history!` currently uses the `MAX_SESSION_HISTORY_SIZE` constant directly.
- `max_sessions::Int` — maximum total active sessions (named + ephemeral) allowed at one time (default: 100). Enforced by `SessionMiddleware` and `SessionOpsMiddleware`.
- `max_concurrent_evals::Int` — maximum number of eval operations that may run concurrently server-wide (default: 10). Enforced by `EvalMiddleware`.
- `rate_limit_per_min::Int` — maximum number of requests a single connection may send per 60-second sliding window (default: 600). Enforced by the transport layer (Phase 7B).
"""
@kwdef struct ResourceLimits
    max_repr_bytes::Int        = DEFAULT_MAX_REPR_BYTES
    max_eval_time_ms::Int      = 30_000
    max_output_bytes::Int      = 1_000_000
    max_session_history::Int   = MAX_SESSION_HISTORY_SIZE
    max_sessions::Int          = 100
    max_concurrent_evals::Int  = 10
    rate_limit_per_min::Int    = 600
end
