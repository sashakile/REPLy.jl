# ResourceLimits — per-request and per-session resource limit configuration.
# All fields have safe defaults suitable for interactive REPL use.

"""
    ResourceLimits(; max_repr_bytes, max_eval_time_ms, max_output_bytes, max_session_history)

Immutable configuration struct for resource limits applied to eval requests and sessions.

Fields:
- `max_repr_bytes::Int` — maximum byte length for `repr` output (default: `DEFAULT_MAX_REPR_BYTES`, 10 KB). Active: used by `EvalMiddleware`.
- `max_eval_time_ms::Int` — maximum wall-clock eval time in milliseconds (default: 30 000). Enforcement deferred to Phase 7 (5wz.2).
- `max_output_bytes::Int` — maximum captured stdout/stderr bytes per eval (default: 1 000 000). Enforcement deferred to Phase 7 (5wz.2).
- `max_session_history::Int` — maximum entries in a named session's history vector (default: `MAX_SESSION_HISTORY_SIZE`, 1000). Enforcement deferred to Phase 7 (5wz.2); `clamp_history!` currently uses the `MAX_SESSION_HISTORY_SIZE` constant directly.
"""
@kwdef struct ResourceLimits
    max_repr_bytes::Int      = DEFAULT_MAX_REPR_BYTES
    max_eval_time_ms::Int    = 30_000
    max_output_bytes::Int    = 1_000_000
    max_session_history::Int = MAX_SESSION_HISTORY_SIZE
end
