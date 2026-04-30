# Load-file middleware — handles `op == "load-file"` requests by reading a Julia
# source file and evaluating it in the session module, with file/line attribution
# in stack traces. Supports an optional path-allowlist hook.

"""
    LoadFileMiddleware(; load_file_allowlist=nothing)

Middleware that handles `op == "load-file"` requests. Reads `file` from disk
and evaluates its content in the active session module using `Base.include_string`
so that stack traces reference the source file path and line numbers.

`load_file_allowlist` must be a function `(path::String) -> Bool` that returns `true`
for permitted paths. When not provided, all file load requests are denied by default —
pass `load_file_allowlist = _ -> true` to allow all files (insecure). Returning `false`
causes the request to fail with a path-not-allowed error before any file I/O occurs,
preventing path enumeration.

All other ops are forwarded to the next middleware.
"""
struct LoadFileMiddleware <: AbstractMiddleware
    load_file_allowlist::Union{Nothing, Function}
end
LoadFileMiddleware(; load_file_allowlist=nothing) = LoadFileMiddleware(load_file_allowlist)

descriptor(::LoadFileMiddleware) = MiddlewareDescriptor(
    provides = Set(["load-file"]),
    op_info  = Dict{String, Dict{String, Any}}(
        "load-file" => Dict{String, Any}(
            "doc"      => "Load and evaluate a Julia source file.",
            "requires" => ["file"],
            "optional" => ["session"],
            "returns"  => ["out", "err", "value", "ns"],
        ),
    ),
)

function handle_message(mw::LoadFileMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "load-file" || return next(msg)
    return load_file_responses(ctx, msg; load_file_allowlist=mw.load_file_allowlist)
end

function load_file_responses(ctx::RequestContext, request::AbstractDict; load_file_allowlist=nothing)
    request_id = String(request["id"])

    file = get(request, "file", nothing)
    file isa AbstractString || return [error_response(request_id, "load-file requires a string file field")]

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
        return [error_response(request_id, "Failed to read file: $(safe_showerror(ex))")]
    end

    ephemeral = isnothing(ctx.session) ? create_ephemeral_session!(ctx.manager) : nothing
    session = something(ephemeral, ctx.session)

    try
        if session isa NamedSession
            lock(session.eval_lock) do
                try_begin_eval!(session, current_task()) ||
                    return [error_response(request_id, "session was closed")]
                try
                    _run_load_file_core(session_module(session), request_id, code, file)
                finally
                    end_eval!(session)
                end
            end
        else
            _run_load_file_core(session_module(session), request_id, code, file)
        end
    finally
        !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral)
    end
end

function _run_load_file_core(module_::Module, request_id::AbstractString, code::AbstractString, file::AbstractString)
    stdout_pipe = Base.Pipe()
    stderr_pipe = Base.Pipe()
    Base.link_pipe!(stdout_pipe; reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(stderr_pipe; reader_supports_async=true, writer_supports_async=true)

    stdout_buf = IOBuffer()
    stderr_buf = IOBuffer()
    stdout_reader = @async write(stdout_buf, stdout_pipe.out)
    stderr_reader = @async write(stderr_buf, stderr_pipe.out)

    try
        eval_result = lock(EVAL_IO_CAPTURE_LOCK) do
            try
                value = redirect_stdout(stdout_pipe.in) do
                    redirect_stderr(stderr_pipe.in) do
                        Base.include_string(module_, code, file)
                    end
                end
                (:ok, value)
            catch ex
                (:error, ex, catch_backtrace())
            end
        end

        close(stdout_pipe.in)
        close(stderr_pipe.in)
        wait(stdout_reader)
        wait(stderr_reader)

        stdout_text = String(take!(stdout_buf))
        stderr_text = String(take!(stderr_buf))

        if first(eval_result) === :error
            _, ex, bt = eval_result
            output_messages = buffered_output_messages(request_id, stdout_text, stderr_text)
            append!(output_messages, [eval_error_response(request_id, ex; bt=bt)])
            return output_messages
        end

        _, value = eval_result
        responses = buffered_output_messages(request_id, stdout_text, stderr_text)
        push!(responses, response_message(request_id, "value" => safe_repr(value), "ns" => string(nameof(module_))))
        push!(responses, done_response(request_id))
        return responses
    finally
        isopen(stdout_pipe.in) && close(stdout_pipe.in)
        isopen(stderr_pipe.in) && close(stderr_pipe.in)
    end
end
