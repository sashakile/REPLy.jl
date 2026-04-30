# ResourceLimits — per-request and per-session resource limit configuration.
# All fields have safe defaults suitable for interactive REPL use.

"""
    ResourceLimits(; max_repr_bytes, max_eval_time_ms, max_output_bytes, max_session_history, max_sessions, max_concurrent_evals, rate_limit_per_min, max_connections, revise_hook_enabled)

Immutable configuration struct for resource limits applied to eval requests and sessions.

Fields:
- `max_repr_bytes::Int` — maximum byte length for `repr` output (default: `DEFAULT_MAX_REPR_BYTES`, 10 KB). Active: used by `EvalMiddleware`.
- `max_eval_time_ms::Int` — maximum wall-clock eval time in milliseconds (default: 30 000). Enforced by `EvalMiddleware` (Phase 7C).
- `max_output_bytes::Int` — maximum captured stdout/stderr bytes per eval (default: 1 000 000). Enforced by `EvalMiddleware` (truncates stdout and stderr independently).
- `max_session_history::Int` — maximum entries in a named session's history vector (default: `MAX_SESSION_HISTORY_SIZE`, 1000). Enforced by `_update_history!` via `clamp_history!`.
- `max_sessions::Int` — maximum total active sessions (named + ephemeral) allowed at one time (default: 100). Enforced by `SessionMiddleware` and `SessionOpsMiddleware`.
- `max_concurrent_evals::Int` — maximum number of eval operations that may run concurrently server-wide (default: 10). Enforced by `EvalMiddleware`.
- `rate_limit_per_min::Int` — maximum number of requests a single connection may send per 60-second sliding window (default: 600). Enforced by the transport layer (Phase 7B).
- `max_connections::Int` — maximum number of simultaneous TCP/Unix connections (default: 100). When the limit is reached, new connections are immediately closed.
- `revise_hook_enabled::Bool` — when `true` (default), `EvalMiddleware` calls `Main.Revise.revise()` before each named-session eval if `Revise` is loaded in `Main`. Set to `false` to disable the hook entirely.
"""
@kwdef struct ResourceLimits
    max_repr_bytes::Int        = DEFAULT_MAX_REPR_BYTES
    max_eval_time_ms::Int      = 30_000
    max_output_bytes::Int      = 1_000_000
    max_session_history::Int   = MAX_SESSION_HISTORY_SIZE
    max_sessions::Int          = 100
    max_concurrent_evals::Int  = 10
    rate_limit_per_min::Int    = 600
    max_connections::Int       = 100
    revise_hook_enabled::Bool  = true
end
