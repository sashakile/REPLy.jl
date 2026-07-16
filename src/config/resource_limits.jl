# ResourceLimits — per-request and per-session resource limit configuration.
# All fields have safe defaults suitable for interactive REPL use.

"""
    ResourceLimits(; ...)

Immutable configuration struct for resource limits applied to eval requests and sessions.
Field names follow the spec table in `openspec/specs/resource-limits/spec.md`.

See the docstring at the definition site for full field documentation.
"""
@kwdef struct ResourceLimits
    max_value_repr_bytes::Int    = 1_048_576
    max_eval_time_ms::Int        = 60_000
    max_output_bytes::Int        = 1_000_000
    max_history_entries::Int     = 10_000
    max_sessions::Int            = 100
    max_concurrent_evals::Int    = 10
    rate_limit_per_min::Int      = 600
    max_connections::Int         = 100
    session_idle_timeout_s::Int  = 3_600
    revise_hook_enabled::Bool    = true
    max_memory_mb::Int           = 2_048
    min_rate_limit_per_min::Int  = 10
    # Missing fields (spec-gap resolved)
    max_id_length::Int           = 256
    max_message_size::Int        = 10_485_760   # 10 MB (spec REQ-RPL-047e)
    max_stdin_buffer::Int        = 16           # spec REQ-RPL-017b
end

"""
    unlimited_resource_limits()

Return a `ResourceLimits` with all limits set to sentinel values that disable
enforcement. Use for contexts where no resource constraints should apply.
"""
function unlimited_resource_limits()
    return ResourceLimits(
        max_value_repr_bytes   = typemax(Int),
        max_eval_time_ms       = typemax(Int),
        max_output_bytes       = typemax(Int),
        max_history_entries    = typemax(Int),
        max_sessions           = typemax(Int),
        max_concurrent_evals   = typemax(Int),
        rate_limit_per_min     = typemax(Int),
        max_connections        = typemax(Int),
        session_idle_timeout_s = typemax(Int),
        revise_hook_enabled    = true,
        max_memory_mb          = typemax(Int),
        min_rate_limit_per_min = 0,
        max_id_length          = typemax(Int),
        max_message_size       = typemax(Int),
        max_stdin_buffer       = typemax(Int),
    )
end
