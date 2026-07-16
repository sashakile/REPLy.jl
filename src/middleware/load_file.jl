# Load-file middleware — handles `op == "load-file"` requests by reading a Julia
# source file and evaluating it in the session module, with file/line attribution
# in stack traces. Supports an optional path-allowlist hook.

"""
    LoadFileMiddleware(; load_file_allowlist=nothing, max_repr_bytes=DEFAULT_MAX_REPR_BYTES)
    LoadFileMiddleware(limits::ResourceLimits; load_file_allowlist=nothing)

Middleware that handles `op == "load-file"` requests. Reads `file` from disk
and evaluates its content in the active session module using `Base.include_string`
so that stack traces reference the source file path and line numbers.

`load_file_allowlist` must be a function `(path::String) -> Bool` that returns `true`
for permitted paths. When not provided, all file load requests are denied by default —
pass `load_file_allowlist = _ -> true` to allow all files (insecure). Returning `false`
causes the request to fail with a path-not-allowed error before any file I/O occurs,
preventing path enumeration.

`max_repr_bytes` bounds the byte length of the returned value's `repr`, mirroring
`EvalMiddleware`. Pass a `ResourceLimits` to derive it from `limits.max_repr_bytes`.

All other ops are forwarded to the next middleware.
"""
struct LoadFileMiddleware <: AbstractMiddleware
    load_file_allowlist::Union{Nothing, Function}
    max_repr_bytes::Int
end
LoadFileMiddleware(; load_file_allowlist=nothing, max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES) =
    LoadFileMiddleware(load_file_allowlist, max_repr_bytes)
LoadFileMiddleware(limits::ResourceLimits; load_file_allowlist=nothing) =
    LoadFileMiddleware(load_file_allowlist, limits.max_value_repr_bytes)

descriptor(::LoadFileMiddleware) = MiddlewareDescriptor(
    provides = Set(["load-file"]),
    op_info  = Dict{String, Dict{String, Any}}(
        "load-file" => Dict{String, Any}(
            "doc"      => "Load and evaluate a Julia source file.",
            "requires" => ["file"],
            "optional" => ["session"],
            "returns"  => ["out", "err", "value", "repr-error", "ns"],
        ),
    ),
)

function handle_message(mw::LoadFileMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "load-file" || return next(msg)
    return load_file_responses(ctx, msg; load_file_allowlist=mw.load_file_allowlist, max_repr_bytes=mw.max_repr_bytes)
end

function load_file_responses(ctx::RequestContext, request::AbstractDict; load_file_allowlist=nothing, max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES)
    request_id = String(request["id"])

    file = get(request, "file", nothing)
    file isa AbstractString || return [error_response(request_id, "load-file requires a string file field";
                        status_flags=String["error", "missing-file-field"])]

    if isnothing(load_file_allowlist)
        return [error_response(
            request_id,
            "load-file requires an explicit allowlist; no files are accessible by default. " *
            "Pass load_file_allowlist = path -> true to allow all paths (insecure).";
            status_flags=String["error", "path-not-allowed"],
        )]
    end
    load_file_allowlist(file) || return [error_response(
        request_id,
        "Path not allowed: $file";
        status_flags=String["error", "path-not-allowed"],
    )]

    code = try
        read(file, String)
    catch ex
        flag, msg = classify_read_error(ex)
        return [error_response(request_id, msg; status_flags=String["error", flag])]
    end

    max_output_bytes = effective_limit(ctx.server_state, :max_output_bytes, typemax(Int))

    with_session_eval(ctx, request_id) do session
        _run_load_file_core(session_module(session), request_id, code, file; max_output_bytes, max_repr_bytes)
    end
end

function _run_load_file_core(module_::Module, request_id::AbstractString, code::AbstractString, file::AbstractString; max_output_bytes::Int=typemax(Int), max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES)
    ensure_io_capture_installed!()
    stdout_cap = _STDOUT_CAPTURER[]::TaskCapturingIO
    stderr_cap = _STDERR_CAPTURER[]::TaskCapturingIO

    task = current_task()
    stdout_buf = IOBuffer()
    stderr_buf = IOBuffer()

    register_task_capture!(stdout_cap, task, stdout_buf)
    register_task_capture!(stderr_cap, task, stderr_buf)

    try
        eval_result = try
            (:ok, Base.include_string(module_, code, file))
        catch ex
            (:error, ex, catch_backtrace())
        end

        stdout_text = truncate_output(String(take!(stdout_buf)), max_output_bytes)
        stderr_text = truncate_output(String(take!(stderr_buf)), max_output_bytes)

        if first(eval_result) === :error
            _, ex, bt = eval_result
            output_messages = buffered_output_messages(request_id, stdout_text, stderr_text)
            append!(output_messages, [eval_error_response(request_id, ex; bt=bt)])
            return output_messages
        end

        _, value = eval_result
        responses = buffered_output_messages(request_id, stdout_text, stderr_text)
        push!(responses, value_response(request_id, value, module_; max_repr_bytes=max_repr_bytes))
        push!(responses, done_response(request_id))
        return responses
    finally
        unregister_task_capture!(stdout_cap, task)
        unregister_task_capture!(stderr_cap, task)
    end
end
