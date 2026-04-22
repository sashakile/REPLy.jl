const DEFAULT_MAX_REPR_BYTES = 10_000  # 10 KiB

const OUTPUT_TRUNCATION_MARKER = "…[truncated]"

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
    catch
        return fallback_render(kind, value)
    end
end

safe_show(value) = safe_render("show", value -> sprint(show, value), value)
safe_showerror(ex) = safe_render("showerror", ex -> sprint(showerror, ex), ex)

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

# Transport-level handler failures intentionally reuse the same wire error
# shape as eval failures so clients see one consistent internal-error format.
function internal_error_response(request_id::AbstractString, ex; bt=catch_backtrace())
    return error_response(request_id, safe_showerror(ex); ex=ex, bt=bt)
end

function eval_error_response(request_id::AbstractString, ex; bt=catch_backtrace())
    return internal_error_response(request_id, ex; bt=bt)
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
