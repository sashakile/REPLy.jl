function exception_message(ex)
    if hasfield(typeof(ex), :msg)
        msg = getfield(ex, :msg)
        return msg isa AbstractString ? String(msg) : sprint(show, msg)
    end
    return sprint(showerror, ex)
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

function eval_error_response(request_id::AbstractString, ex; bt=catch_backtrace())
    return error_response(request_id, sprint(showerror, ex); ex=ex, bt=bt)
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
