# Eval middleware — intercepts `op == "eval"` requests, executes code in the
# session module with captured I/O, and returns value/out/err/done messages.
# All other ops are forwarded to the next middleware in the stack.

"""
    EvalMiddleware(; max_repr_bytes=DEFAULT_MAX_REPR_BYTES)

Middleware that handles `op == "eval"` requests. Executes Julia code in the
active session module with captured stdout/stderr, truncates the `repr` of the
return value at `max_repr_bytes`, and returns a sequence of response messages
(out, err, value, done). Passes all other ops to the next middleware.

Named sessions are serialized per session via `session.eval_lock` (FIFO within
a session; independent across sessions). Ephemeral sessions have no cross-request
state and need no serialization.
"""
struct EvalMiddleware <: AbstractMiddleware
    max_repr_bytes::Int
end
EvalMiddleware(; max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES) = EvalMiddleware(max_repr_bytes)

# `redirect_stdout(IOStream)` uses dup2 (a process-global operation), so concurrent
# calls would race on file descriptors 1 and 2.  This lock serializes IO capture
# globally; per-session eval_lock handles FIFO ordering within each named session.
const EVAL_IO_CAPTURE_LOCK = ReentrantLock()

safe_repr(value; max_bytes::Int=DEFAULT_MAX_REPR_BYTES) = truncate_output(safe_render("repr", repr, value), max_bytes)

function buffered_output_messages(request_id::AbstractString, stdout_text::AbstractString, stderr_text::AbstractString)
    messages = Dict{String, Any}[]
    !isempty(stdout_text) && push!(messages, response_message(request_id, "out" => stdout_text))
    !isempty(stderr_text) && push!(messages, response_message(request_id, "err" => stderr_text))
    return messages
end

function read_captured_output(io::IO)
    flush(io)
    seekstart(io)
    return read(io, String)
end

function eval_parsed(module_::Module, exprs)
    if exprs isa Expr && exprs.head == :toplevel
        value = nothing
        for expr in exprs.args
            value = Core.eval(module_, expr)
        end
        return value
    end

    return Core.eval(module_, exprs)
end

function _run_eval_core(module_::Module, request_id::AbstractString, code::AbstractString, max_repr_bytes::Int)
    stdout_path, stdout_io = mktemp()
    stderr_path, stderr_io = mktemp()

    try
        result = lock(EVAL_IO_CAPTURE_LOCK) do
            value = try
                redirect_stdout(stdout_io) do
                    redirect_stderr(stderr_io) do
                        if isempty(strip(code))
                            nothing
                        else
                            eval_parsed(module_, Meta.parseall(code))
                        end
                    end
                end
            catch ex
                output_messages = buffered_output_messages(
                    request_id,
                    read_captured_output(stdout_io),
                    read_captured_output(stderr_io),
                )
                append!(output_messages, [eval_error_response(request_id, ex; bt=catch_backtrace())])
                return output_messages
            end

            # Read captured output before releasing the IO lock.
            # safe_repr does not need the lock — it is computed after.
            stdout_text = read_captured_output(stdout_io)
            stderr_text = read_captured_output(stderr_io)
            (value, stdout_text, stderr_text)
        end

        # `result` is either a Vector{Dict} (error path) or a 3-tuple (success path).
        result isa Vector && return result
        value, stdout_text, stderr_text = result

        responses = buffered_output_messages(request_id, stdout_text, stderr_text)
        push!(responses, response_message(request_id, "value" => safe_repr(value; max_bytes=max_repr_bytes), "ns" => string(nameof(module_))))
        push!(responses, done_response(request_id))
        return responses
    finally
        close(stdout_io)
        close(stderr_io)
        rm(stdout_path; force=true)
        rm(stderr_path; force=true)
    end
end

function eval_responses(ctx::RequestContext, request::AbstractDict; max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES)
    request_id = String(request["id"])
    code = get(request, "code", "")
    code isa AbstractString || return [error_response(request_id, "code must be a string")]

    # Defensive ephemeral fallback: SessionMiddleware normally provides a session
    # before we reach this point.  This guard exists as a safety net for callers
    # that bypass the middleware stack (e.g., direct eval_responses calls in tests
    # or alternative pipelines).  With the default stack it is effectively dead code.
    ephemeral = isnothing(ctx.session) ? create_ephemeral_session!(ctx.manager) : nothing
    session = something(ephemeral, ctx.session)

    try
        if session isa NamedSession
            # Serialize evals within this session (FIFO); independent across sessions.
            # try_begin_eval! handles the race where destroy_named_session! runs concurrently:
            # it returns false (no throw) when the session is already SessionClosed.
            lock(session.eval_lock) do
                try_begin_eval!(session, current_task()) ||
                    return [error_response(request_id, "session was closed")]
                try
                    _run_eval_core(session_module(session), request_id, code, max_repr_bytes)
                finally
                    end_eval!(session)
                end
            end
        else
            _run_eval_core(session_module(session), request_id, code, max_repr_bytes)
        end
    finally
        !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral)
    end
end

function handle_message(mw::EvalMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "eval" || return next(msg)
    return eval_responses(ctx, msg; max_repr_bytes=mw.max_repr_bytes)
end
