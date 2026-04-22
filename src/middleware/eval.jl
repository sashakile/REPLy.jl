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
EvalMiddleware(limits::ResourceLimits) = EvalMiddleware(limits.max_repr_bytes)  # only max_repr_bytes is active; other fields deferred to Phase 7

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

function _run_eval_core(module_::Module, request_id::AbstractString, code::AbstractString, max_repr_bytes::Int; silent::Bool=false)
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
                if ex isa InterruptException
                    push!(output_messages, response_message(request_id, "status" => ["done", "interrupted"]))
                else
                    append!(output_messages, [eval_error_response(request_id, ex; bt=catch_backtrace())])
                end
                return output_messages
            end

            # Read captured output before releasing the IO lock.
            # safe_repr does not need the lock — it is computed after.
            stdout_text = read_captured_output(stdout_io)
            stderr_text = read_captured_output(stderr_io)
            (value, stdout_text, stderr_text)
        end

        # `result` is either a Vector{Dict} (error path) or a 3-tuple (success path).
        result isa Vector && return (result, nothing)
        value, stdout_text, stderr_text = result

        responses = buffered_output_messages(request_id, stdout_text, stderr_text)
        if !silent
            push!(responses, response_message(request_id, "value" => safe_repr(value; max_bytes=max_repr_bytes), "ns" => string(nameof(module_))))
        end
        push!(responses, done_response(request_id))
        return (responses, Some(value))
    finally
        close(stdout_io)
        close(stderr_io)
        rm(stdout_path; force=true)
        rm(stderr_path; force=true)
    end
end

"""
    resolve_module(module_path) -> Module or nothing

Resolve a dotted module path (e.g. `"Main.Foo.Bar"`) by walking the module
hierarchy starting from `Main`. Returns `nothing` if any segment is missing or
not a `Module`.

Limitation: only `Main`-rooted paths are supported. Modules created inside a
named session's anonymous module cannot be addressed via this function.
"""
function resolve_module(module_path::AbstractString)
    parts = split(module_path, '.')
    isempty(parts) && return nothing
    sym = Symbol(parts[1])
    isdefined(Main, sym) || return nothing
    mod = getfield(Main, sym)
    mod isa Module || return nothing
    for part in parts[2:end]
        s = Symbol(part)
        isdefined(mod, s) || return nothing
        child = getfield(mod, s)
        child isa Module || return nothing
        mod = child
    end
    return mod
end

# Feeder task: reads text from `channel` and writes to `pipe_in`.
# Stops on InterruptException (scheduled by the eval's finally block) or
# when the pipe is closed. Unconsumed channel items are left for the next eval.
function _stdin_feeder(channel::Channel{String}, pipe_in::IO)
    try
        while true
            text = take!(channel)   # blocks until stdin arrives
            write(pipe_in, text)
        end
    catch ex
        # Normal stops: InterruptException (eval finished) or IOError/EOFError (pipe closed).
        ex isa InterruptException || ex isa Base.IOError || ex isa EOFError || rethrow()
    end
end

function eval_responses(ctx::RequestContext, request::AbstractDict; max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES)
    request_id = String(request["id"])
    code = get(request, "code", "")
    code isa AbstractString || return [error_response(request_id, "code must be a string")]

    # timeout-ms validation: must be a positive integer when present.
    timeout_ms = get(request, "timeout-ms", nothing)
    if !isnothing(timeout_ms)
        if !(timeout_ms isa Integer)
            return [error_response(request_id, "timeout-ms must be a positive integer")]
        end
        if timeout_ms < 1
            return [error_response(request_id, "timeout-ms must be ≥ 1")]
        end
        # Capping to ResourceLimits.max_eval_time_ms is deferred to Phase 7.
    end

    silent = get(request, "silent", false) === true
    allow_stdin = get(request, "allow-stdin", true) !== false
    store_history = get(request, "store-history", true) !== false

    # Concurrent eval limit enforcement
    if !isnothing(ctx.server_state)
        limit = ctx.server_state.limits.max_concurrent_evals
        current = Threads.atomic_add!(ctx.server_state.active_evals, 1)
        if current >= limit
            Threads.atomic_sub!(ctx.server_state.active_evals, 1)
            return [error_response(request_id, "Too many concurrent evals";
                        status_flags=String["error", "concurrency-limit-reached"])]
        end
    end

    # Defensive ephemeral fallback: SessionMiddleware normally provides a session
    # before we reach this point.  This guard exists as a safety net for callers
    # that bypass the middleware stack (e.g., direct eval_responses calls in tests
    # or alternative pipelines).  With the default stack it is effectively dead code.
    ephemeral = isnothing(ctx.session) ? create_ephemeral_session!(ctx.manager) : nothing
    session = something(ephemeral, ctx.session)

    # module routing: resolve dotted path when the "module" field is present.
    eval_module = session_module(session)
    module_path = get(request, "module", nothing)
    if module_path isa AbstractString
        resolved = resolve_module(module_path)
        if isnothing(resolved)
            !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral)
            !isnothing(ctx.server_state) && Threads.atomic_sub!(ctx.server_state.active_evals, 1)
            return [error_response(request_id, "Cannot resolve module: $(module_path)")]
        end
        eval_module = resolved
    end

    try
        if session isa NamedSession
            # Serialize evals within this session (FIFO); independent across sessions.
            # try_begin_eval! handles the race where destroy_named_session! runs concurrently:
            # it returns false (no throw) when the session is already SessionClosed.
            lock(session.eval_lock) do
                try_begin_eval!(session, current_task()) ||
                    return [error_response(request_id, "session was closed")]
                msgs, captured = if allow_stdin
                    # Pipe + feeder task: bridges session.stdin_channel to the eval's
                    # redirected stdin. redirect_stdin requires a Pipe, not a generic IO.
                    pipe = Base.Pipe()
                    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
                    feeder = @async _stdin_feeder(session.stdin_channel, pipe.in)
                    try
                        redirect_stdin(pipe.out) do
                            _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent)
                        end
                    finally
                        schedule(feeder, InterruptException(); error=true)
                        close(pipe.in)
                        close(pipe.out)
                        end_eval!(session)
                    end
                else
                    # allow-stdin false: redirect stdin to devnull so byte reads raise EOFError.
                    try
                        redirect_stdin(devnull) do
                            _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent)
                        end
                    finally
                        end_eval!(session)
                    end
                end
                _update_history!(session, captured, store_history)
                msgs
            end
        else
            msgs, _ = if allow_stdin
                _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent)
            else
                redirect_stdin(devnull) do
                    _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent)
                end
            end
            msgs
        end
    finally
        !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral)
        !isnothing(ctx.server_state) && Threads.atomic_sub!(ctx.server_state.active_evals, 1)
    end
end

# Update ans binding and history for `session` when `store_history` is true
# and `captured` is `Some(value)` (successful eval). Does nothing on error.
function _update_history!(session::NamedSession, captured::Union{Some, Nothing}, store_history::Bool)
    store_history && !isnothing(captured) || return
    value = something(captured)
    try
        Core.eval(session_module(session), :(ans = $(QuoteNode(value))))
    catch
        # If ans update fails (e.g. type not quotable), skip silently.
    end
    push!(session.history, value)
    clamp_history!(session)
    return
end

function handle_message(mw::EvalMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "eval" || return next(msg)
    return eval_responses(ctx, msg; max_repr_bytes=mw.max_repr_bytes)
end
