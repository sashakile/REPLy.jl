const DEFAULT_MAX_REPR_BYTES = 1_048_576  # 1 MB (spec: max_value_repr_bytes)

const OUTPUT_TRUNCATION_MARKER = "…[truncated]"

# Tracks unexpected exceptions caught by safe_render (bare-catch safety net).
# Incremented each time safe_render catches an exception; exposed for test
# introspection and observability.
const _safe_render_error_counter = Threads.Atomic{Int}(0)

"""
    safe_render_error_count() -> Int

Return the number of exceptions caught by `safe_render` since module load.
Useful for test assertions and observability probes.
"""
safe_render_error_count() = _safe_render_error_counter[]

function truncate_output(s::AbstractString, max_bytes::Int)
    max_bytes > 0 || throw(ArgumentError("max_bytes must be positive, got $max_bytes"))
    ncodeunits(s) <= max_bytes && return s
    j = thisind(s, max_bytes)
    # If the character at j extends past max_bytes, back up to the previous boundary.
    next_boundary = nextind(s, j) - 1
    j = next_boundary > max_bytes ? prevind(s, j) : j
    return s[1:j] * OUTPUT_TRUNCATION_MARKER
end

function safe_type_name(value)
    type_string = string(typeof(value))
    return replace(type_string, r"(?:^|\{|, )[^\{, ]+\." => s -> startswith(s, "{") || startswith(s, ", ") ? s[end-1:end] : "")
end

# Placeholder format is intentionally stable because it is client-visible.
fallback_render(kind::AbstractString, value) = "<$(kind) failed: $(safe_type_name(value))>"

function safe_render(kind::AbstractString, renderer, value)
    try
        return renderer(value)
    catch ex
        @debug "safe_render caught exception" kind=kind exception=ex
        Threads.atomic_add!(_safe_render_error_counter, 1)
        return fallback_render(kind, value)
    end
end

safe_show(value) = safe_render("show", value -> sprint(show, value), value)
safe_showerror(ex) = safe_render("showerror", ex -> sprint(showerror, ex), ex)

"""
    try_repr(value; max_bytes=DEFAULT_MAX_REPR_BYTES) -> Tuple

Render `repr(value)` truncated to `max_bytes`, distinguishing success from
failure so callers can flag the two cases separately on the wire:

- `(:ok, repr_string)` when `repr` succeeds.
- `(:error, type_name)` when `repr` throws — `type_name` is the (module-stripped)
  type name of `value`.

Unlike `safe_repr`, this does not fold a failure into a `"<repr failed: …>"`
string that is indistinguishable from a legitimately-returned string.
"""
function try_repr(value; max_bytes::Int=DEFAULT_MAX_REPR_BYTES)
    rendered = try
        repr(value)
    catch
        return (:error, safe_type_name(value))
    end
    return (:ok, truncate_output(rendered, max_bytes))
end

function exception_message(ex)
    if hasfield(typeof(ex), :msg)
        msg = getfield(ex, :msg)
        return msg isa AbstractString ? String(msg) : safe_show(msg)
    end
    return safe_showerror(ex)
end

function stacktrace_payload(bt)
    return [
        Dict(
            "func" => string(frame.func),
            "file" => string(frame.file),
            "line" => frame.line,
        ) for frame in stacktrace(bt)
    ]
end

# Transport-level handler failures return a stable error message and a
# correlation id (UUID) for server-side log lookup. Full exception details
# and stack traces are never leaked to the client by default.
#
# When `expose_trace=true` (opt-in for loopback connections), the full
# exception type, message, and stack trace are included in the response.
function internal_error_response(request_id::AbstractString, ex; bt=catch_backtrace(), expose_trace=false)
    correlation_id = string(uuid4())
    @error "Internal handler failure" correlation_id=correlation_id request_id=request_id exception=(ex, bt)
    if expose_trace
        return error_response(request_id, safe_showerror(ex); ex=ex, bt=bt, correlation_id=correlation_id)
    end
    return error_response(
        request_id,
        "Internal server error — contact administrator with correlation id: $(correlation_id)";
        correlation_id=correlation_id,
    )
end

function eval_error_response(request_id::AbstractString, ex; bt=catch_backtrace())
    return error_response(request_id, safe_showerror(ex); ex=ex, bt=bt)
end

function unknown_op_response(request_id::AbstractString, op::AbstractString)
    return error_response(
        request_id,
        "Unknown operation: $(op)";
        status_flags=String["error", "unknown-op"],
    )
end

function session_not_found_response(request_id::AbstractString, session_id::AbstractString)
    return error_response(
        request_id,
        "Session not found: $(session_id)";
        status_flags=String["error", "session-not-found"],
    )
end

"""
    SessionLimitReachedError()

Thrown by `clone_named_session!` when the session limit is reached inside a lock,
so callers can distinguish a limit hit from a missing source session without
changing the function's return type.
"""
struct SessionLimitReachedError <: Exception end

"""
    MalformedJSONError()

Thrown by `receive` when the wire message cannot be parsed as valid JSON.
Callers should respond with a `malformed-request` error status and decide
whether to close the connection based on their own consecutive-count policy.
"""
struct MalformedJSONError <: Exception end

function session_limit_response(request_id::AbstractString)
    return error_response(
        request_id,
        "Session limit reached";
        status_flags=String["error", "session-limit-reached"],
    )
end

"""
    classify_read_error(ex) -> (status_flag::String, safe_message::String)

Classify an exception raised by `read(file, String)` into a stable error code
and a safe (path-free) error message. Intended to prevent sensitive paths from
leaking to clients.

Mapping:
- `SystemError` with errnum == 2 (ENOENT) → `file-not-found`
- `SystemError` with errnum == 13 (EACCES) → `path-not-allowed`
- Other `SystemError` → `io-error`
- `ArgumentError` → `io-error`
- Any other exception → `io-error`
"""
function classify_read_error(ex)
    if ex isa SystemError
        if ex.errnum == 2   # ENOENT
            return ("file-not-found", "File not found")
        elseif ex.errnum == 13  # EACCES
            return ("path-not-allowed", "Permission denied — path not accessible")
        else
            return ("io-error", "I/O error reading file")
        end
    elseif ex isa ArgumentError
        return ("io-error", "Invalid file path")
    end
    return ("io-error", "Unexpected error reading file")
end
