"""
    EvalRequest

A validated, typed representation of an `eval` request, parsed at the middleware
handler boundary. Once parsed, downstream code never re-fetches fields from the
raw `Dict` or re-validates types — the struct guarantees correctness.

Fields match the spec's eval op schema:
- `id::String` — request identifier (must be non-empty after `validate_request`)
- `code::String` — Julia code to evaluate
- `session::Union{Nothing, String}` — optional named session alias
- `module_path::Union{Nothing, String}` — optional fully-qualified module path
- `timeout_ms::Union{Nothing, Int}` — optional per-request timeout (≥ 1)
- `silent::Bool` — suppress value output (default: false)
- `allow_stdin::Bool` — allow stdin reads during eval (default: true)
- `store_history::Bool` — persist result to session history (default: true)
"""
struct EvalRequest
    id::String
    code::String
    session::Union{Nothing, String}
    module_path::Union{Nothing, String}
    timeout_ms::Union{Nothing, Int}
    silent::Bool
    allow_stdin::Bool
    store_history::Bool
end

"""
    parse_eval_request(request::AbstractDict) -> EvalRequest

Parse and validate a raw eval request dict into a typed `EvalRequest`.

Returns the `EvalRequest` on success. Throws `ArgumentError` with a
human-readable message on validation failure — callers should catch and
convert to an error response.

**Validation rules:**
- `code` must be a string (defaults to empty if absent)
- `timeout-ms` must be a positive integer if present
- `session` must be a string if present
- `module_path` must be a string if present
- `silent`, `allow-stdin`, `store-history` are parsed as booleans
"""
function parse_eval_request(request::AbstractDict)
    request_id = String(request["id"])
    code = get(request, "code", "")
    code isa AbstractString || throw(ArgumentError("code must be a string"))

    session_raw = get(request, "session", nothing)
    session = session_raw isa AbstractString ? String(session_raw) : nothing

    module_raw = get(request, "module", nothing)
    module_path = module_raw isa AbstractString ? String(module_raw) : nothing

    timeout_ms_raw = get(request, "timeout-ms", nothing)
    timeout_ms = if !isnothing(timeout_ms_raw)
        timeout_ms_raw isa Integer || throw(ArgumentError("timeout-ms must be a positive integer"))
        timeout_ms_raw < 1 && throw(ArgumentError("timeout-ms must be ≥ 1"))
        Int(timeout_ms_raw)
    else
        nothing
    end

    silent      = get(request, "silent", false) === true
    allow_stdin = get(request, "allow-stdin", true) !== false
    store_history = get(request, "store-history", true) !== false

    return EvalRequest(
        request_id, String(code),
        session, module_path,
        timeout_ms,
        silent, allow_stdin, store_history,
    )
end
