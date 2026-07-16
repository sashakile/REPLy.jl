# ResourceLimits — per-request and per-session resource limit configuration.
# All fields have safe defaults suitable for interactive REPL use.

"""
    ResourceLimits(; max_value_repr_bytes, max_eval_time_ms, max_output_bytes, max_history_entries, max_sessions, max_concurrent_evals, rate_limit_per_min, max_connections, session_idle_timeout_s, revise_hook_enabled, max_memory_mb, min_rate_limit_per_min)

Immutable configuration struct for resource limits applied to eval requests and sessions.
Field names follow the spec table in `openspec/specs/resource-limits/spec.md`.

Fields:
- `max_value_repr_bytes::Int` — maximum byte length for `repr` output (spec name: `max_value_repr_bytes`; code name: `max_repr_bytes`). Default: 1,048,576 (1 MB). Enforced by `EvalMiddleware` and `LoadFileMiddleware`.
- `max_eval_time_ms::Int` — maximum wall-clock eval time in milliseconds (default: 60,000 = 60 s). Enforced by `EvalMiddleware`.
- `max_output_bytes::Int` — maximum captured stdout/stderr bytes per eval (default: 1,000,000). Enforced by `EvalMiddleware`.
- `max_history_entries::Int` — maximum entries in a named session's history vector (spec name: `max_history_entries`; code name: `max_session_history`). Default: 10,000. Enforced by `_update_history!` via `clamp_history!`.
- `max_sessions::Int` — maximum total active sessions (named + ephemeral) allowed at one time (default: 100). Enforced by `SessionMiddleware` and `SessionOpsMiddleware`.
- `max_concurrent_evals::Int` — maximum number of eval operations that may run concurrently server-wide (default: 10). Enforced by `EvalMiddleware`.
- `rate_limit_per_min::Int` — maximum number of requests a single connection may send per 60-second sliding window (default: 600). Enforced by the transport layer.
- `max_connections::Int` — maximum number of simultaneous TCP/Unix connections (default: 100). When the limit is reached, new connections are immediately closed.
- `session_idle_timeout_s::Int` — seconds of inactivity after which a named session is automatically closed (default: 3,600 = 1 hour). Enforced by `sweep_idle_sessions!`.
- `revise_hook_enabled::Bool` — when `true` (default), `EvalMiddleware` calls `Main.Revise.revise()` before each named-session eval if `Revise` is loaded in `Main`. Set to `false` to disable the hook entirely.
- `max_memory_mb::Int` — maximum memory usage in MB (default: 2,048 = 2 GB). Not yet enforced.
- `min_rate_limit_per_min::Int` — minimum rate limit per connection (default: 10, informative). Not yet enforced.

!!! note "Backward compatibility"
    The old field names `max_repr_bytes` and `max_session_history` are deprecated.
    Use `max_value_repr_bytes` and `max_history_entries` instead.
"""
@kwdef struct ResourceLimits
    max_value_repr_bytes::Int  = 1_048_576
    max_eval_time_ms::Int      = 60_000
    max_output_bytes::Int      = 1_000_000
    max_history_entries::Int   = 10_000
    max_sessions::Int          = 100
    max_concurrent_evals::Int  = 10
    rate_limit_per_min::Int    = 600
    max_connections::Int       = 100
    session_idle_timeout_s::Int = 3_600
    revise_hook_enabled::Bool  = true
    max_memory_mb::Int         = 2_048
    min_rate_limit_per_min::Int = 10
end
