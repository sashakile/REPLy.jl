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
EvalMiddleware(limits::ResourceLimits) = EvalMiddleware(limits.max_repr_bytes)

descriptor(::EvalMiddleware) = MiddlewareDescriptor(
    provides = Set(["eval"]),
    requires = Set(["session"]),
    expects  = ["must appear after SessionMiddleware"],
    op_info  = Dict{String, Dict{String, Any}}(
        "eval" => Dict{String, Any}(
            "doc"      => "Evaluate Julia code in a session module.",
            "requires" => ["code"],
            "optional" => ["session", "module", "timeout-ms", "allow-stdin", "silent", "store-history"],
            "returns"  => ["out", "err", "value", "ns"],
        ),
    ),
)


safe_repr(value; max_bytes::Int=DEFAULT_MAX_REPR_BYTES) = truncate_output(safe_render("repr", repr, value), max_bytes)

function buffered_output_messages(request_id::AbstractString, stdout_text::AbstractString, stderr_text::AbstractString)
    messages = Dict{String, Any}[]
    !isempty(stdout_text) && push!(messages, response_message(request_id, "out" => stdout_text))
    !isempty(stderr_text) && push!(messages, response_message(request_id, "err" => stderr_text))
    return messages
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

function _run_eval_core(module_::Module, request_id::AbstractString, code::AbstractString, max_repr_bytes::Int; silent::Bool=false, max_output_bytes::Int=typemax(Int))
    # Pipe-based capture replaces mktemp: no filesystem I/O on the eval hot-path.
    # dup2 is still process-global, so EVAL_IO_CAPTURE_LOCK serializes redirects.
    # Async readers drain each pipe into an IOBuffer to prevent deadlock when
    # eval output exceeds the OS pipe buffer (~64 KiB on Linux).
    stdout_pipe = Base.Pipe()
    stderr_pipe = Base.Pipe()
    Base.link_pipe!(stdout_pipe; reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(stderr_pipe; reader_supports_async=true, writer_supports_async=true)

    stdout_buf = IOBuffer()
    stderr_buf = IOBuffer()

    # Start readers before acquiring the lock so they drain output while the eval runs.
    stdout_reader = @async write(stdout_buf, stdout_pipe.out)
    stderr_reader = @async write(stderr_buf, stderr_pipe.out)

    try
        # (:ok, value) on success; (:error, ex, bt) on exception.
        eval_result = lock(EVAL_IO_CAPTURE_LOCK) do
            try
                value = redirect_stdout(stdout_pipe.in) do
                    redirect_stderr(stderr_pipe.in) do
                        if isempty(strip(code))
                            nothing
                        else
                            eval_parsed(module_, Meta.parseall(code))
                        end
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

        stdout_text = truncate_output(String(take!(stdout_buf)), max_output_bytes)
        stderr_text = truncate_output(String(take!(stderr_buf)), max_output_bytes)

        if first(eval_result) === :error
            _, ex, bt = eval_result
            output_messages = buffered_output_messages(request_id, stdout_text, stderr_text)
            if ex isa InterruptException
                push!(output_messages, response_message(request_id, "status" => ["done", "interrupted"]))
            else
                append!(output_messages, [eval_error_response(request_id, ex; bt=bt)])
            end
            return (output_messages, nothing)
        end

        _, value = eval_result
        responses = buffered_output_messages(request_id, stdout_text, stderr_text)
        if !silent
            push!(responses, response_message(request_id, "value" => safe_repr(value; max_bytes=max_repr_bytes), "ns" => string(nameof(module_))))
        end
        push!(responses, done_response(request_id))
        return (responses, Some(value))
    finally
        # Close write ends if not already done (e.g., InterruptException escaped the
        # lock wait). Readers will drain buffered bytes and terminate on EOF.
        isopen(stdout_pipe.in) && close(stdout_pipe.in)
        isopen(stderr_pipe.in) && close(stderr_pipe.in)
    end
end

# Root module names that may not be targeted via the "module" field in eval requests.
# Routing eval into Main, Base, or Core bypasses session isolation — code executed there
# affects all sessions and the full Julia process.
const PROTECTED_ROOT_MODULES = Set{String}(["Main", "Base", "Core"])

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
    # Block eval routing into protected root modules.
    String(parts[1]) in PROTECTED_ROOT_MODULES && return nothing
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

# UUID of the authentic Revise.jl package (registered in the Julia General registry).
# Used to reject shadow modules injected via eval.
const _REVISE_PKG_ID = Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise")

"""
    _revise_if_present()

Inner implementation for the Revise hook: checks whether `Main.Revise` and
`Main.Revise.revise` are defined in the *current* world age and, if so, calls
`revise()`.

This function is intended to be invoked via `Base.invokelatest` (see
`_maybe_revise!`) so that it executes in the latest world — necessary when
Revise (or a test mock) was loaded after the `REPLy` module was compiled.

Security: only calls `revise()` when `Main.Revise` is the authentic Revise
package (verified via `Base.loaded_modules`). A shadow module eval'd into
`Main` under the name `Revise` will not appear in `Base.loaded_modules` with
the correct PkgId and is silently ignored.
"""
function _revise_if_present()
    isdefined(Main, :Revise) || return nothing
    isdefined(Main.Revise, :revise) || return nothing
    # Guard: Main.Revise must be the module the package manager loaded for the
    # authentic Revise package.  An attacker-injected shadow module bypasses
    # this because it is never registered in Base.loaded_modules.
    get(Base.loaded_modules, _REVISE_PKG_ID, nothing) === Main.Revise || return nothing
    Main.Revise.revise()
    return nothing
end

"""
    _maybe_revise!()

Call `Main.Revise.revise()` if Revise is loaded in `Main` and defines a
callable `revise` function.  Any error thrown by `revise()` is caught and
logged with `@warn` — it must never abort the eval that follows.

The entire check-and-call is dispatched via `Base.invokelatest` so that
`Main.Revise` bindings created after `REPLy` was compiled (including test
mocks) are always visible regardless of the current world age.
"""
function _maybe_revise!()
    try
        Base.invokelatest(_revise_if_present)
    catch ex
        @warn "Revise.revise() failed; continuing eval" exception=(ex, catch_backtrace())
    end
    return nothing
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
    end

    # Effective timeout: per-request value capped at server max, or server max alone.
    effective_timeout_ms = if !isnothing(timeout_ms) && !isnothing(ctx.server_state)
        min(Int(timeout_ms), ctx.server_state.limits.max_eval_time_ms)
    elseif !isnothing(timeout_ms)
        Int(timeout_ms)
    elseif !isnothing(ctx.server_state)
        ctx.server_state.limits.max_eval_time_ms
    else
        nothing
    end

    silent        = get(request, "silent", false) === true
    allow_stdin   = get(request, "allow-stdin", true) !== false
    store_history = get(request, "store-history", true) !== false

    max_output_bytes    = isnothing(ctx.server_state) ? typemax(Int) : ctx.server_state.limits.max_output_bytes
    max_session_history = isnothing(ctx.server_state) ? MAX_SESSION_HISTORY_SIZE : ctx.server_state.limits.max_session_history

    # Defensive ephemeral fallback: SessionMiddleware normally provides a session
    # before we reach this point.  This guard exists as a safety net for callers
    # that bypass the middleware stack (e.g., direct eval_responses calls in tests
    # or alternative pipelines).  With the default stack it is effectively dead code.
    ephemeral = isnothing(ctx.session) ? create_ephemeral_session!(ctx.manager) : nothing
    session = something(ephemeral, ctx.session)

    # module routing: resolved before concurrency registration so that an invalid
    # module path returns early without ever touching active_evals or active_eval_tasks.
    eval_module = session_module(session)
    module_path = get(request, "module", nothing)
    if module_path isa AbstractString
        resolved = resolve_module(module_path)
        if isnothing(resolved)
            !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral)
            return [error_response(request_id, "Cannot resolve module: $(module_path)")]
        end
        eval_module = resolved
    end

    # Concurrent eval limit enforcement — after module resolution so a bad module path
    # never increments active_evals or registers the task.
    state = ctx.server_state
    if !isnothing(state)
        limit = state.limits.max_concurrent_evals
        current = Threads.atomic_add!(state.active_evals, 1)
        if current >= limit
            Threads.atomic_sub!(state.active_evals, 1)
            !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral)
            return [error_response(request_id, "Too many concurrent evals";
                        status_flags=String["error", "concurrency-limit-reached"])]
        end
        register_active_eval!(state, current_task())
    end

    # Timeout state: timed_out is set by the Timer callback before firing InterruptException.
    # timeout_timer is closed (cancelled) in the finally block when the eval completes.
    timed_out = Ref(false)
    timeout_timer = Ref{Union{Timer, Nothing}}(nothing)

    if !isnothing(effective_timeout_ms)
        eval_task = current_task()
        timeout_timer[] = Timer(effective_timeout_ms / 1000.0) do _
            istaskdone(eval_task) && return
            timed_out[] = true
            try
                schedule(eval_task, InterruptException(); error=true)
            catch
            end
        end
    end

    # For named sessions, eval_id is captured after try_begin_eval! increments it.
    # Nothing for ephemeral sessions (they have no persistent identity).
    this_eval_id = Ref{Union{Int, Nothing}}(nothing)

    try
        msgs = try
            if session isa NamedSession
                # Serialize evals within this session (FIFO); independent across sessions.
                # try_begin_eval! handles the race where destroy_named_session! runs concurrently:
                # it returns false (no throw) when the session is already SessionClosed.
                lock(session.eval_lock) do
                    try_begin_eval!(session, current_task()) ||
                        return [error_response(request_id, "session was closed")]
                    this_eval_id[] = session_eval_id(session)
                    # Revise hook: call Revise.revise() before each named-session eval
                    # so long-running sessions pick up code changes automatically.
                    # The hook is skipped when revise_hook_enabled=false in server limits.
                    revise_enabled = isnothing(ctx.server_state) || ctx.server_state.limits.revise_hook_enabled
                    revise_enabled && _maybe_revise!()
                    inner_msgs, captured = if allow_stdin
                        # Pipe + feeder task: bridges session.stdin_channel to the eval's
                        # redirected stdin. redirect_stdin requires a Pipe, not a generic IO.
                        pipe = Base.Pipe()
                        Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
                        feeder = @async _stdin_feeder(session.stdin_channel, pipe.in)
                        try
                            redirect_stdin(pipe.out) do
                                _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent, max_output_bytes)
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
                                _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent, max_output_bytes)
                            end
                        finally
                            end_eval!(session)
                        end
                    end
                    _update_history!(session, captured, store_history, max_session_history)
                    inner_msgs
                end
            else
                m, _ = if allow_stdin
                    _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent, max_output_bytes)
                else
                    redirect_stdin(devnull) do
                        _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent, max_output_bytes)
                    end
                end
                m
            end
        catch ex
            # InterruptException may escape _run_eval_core if it fires in the narrow
            # window during redirect setup rather than inside eval_parsed itself.
            ex isa InterruptException || rethrow()
            if timed_out[]
                [response_message(request_id, "status" => ["done", "error", "timeout"], "err" => "eval timed out")]
            else
                [response_message(request_id, "status" => ["done", "interrupted"])]
            end
        end

        # Replace any "interrupted" terminal with a "timeout" response when the timer fired.
        if timed_out[]
            msgs = map(msgs) do m
                if haskey(m, "status") && "interrupted" in m["status"]
                    response_message(request_id, "status" => ["done", "error", "timeout"],
                        "err" => "eval timed out")
                else
                    m
                end
            end
        end

        # Annotate the terminal message with eval-id for named sessions.
        if !isnothing(this_eval_id[])
            eid = this_eval_id[]
            msgs = map(msgs) do m
                haskey(m, "status") ? merge(m, Dict{String,Any}("eval-id" => eid)) : m
            end
        end

        msgs
    finally
        # Cancel the timeout timer (no-op if already fired or never started).
        t = timeout_timer[]
        !isnothing(t) && close(t)
        !isnothing(ephemeral) && destroy_session!(ctx.manager, ephemeral)
        if !isnothing(state)
            unregister_active_eval!(state, current_task())
            Threads.atomic_sub!(state.active_evals, 1)
        end
    end
end

# Update ans binding and history for `session` when `store_history` is true
# and `captured` is `Some(value)` (successful eval). Does nothing on error.
function _update_history!(session::NamedSession, captured::Union{Some, Nothing}, store_history::Bool, max_session_history::Int=MAX_SESSION_HISTORY_SIZE)
    store_history && !isnothing(captured) || return
    value = something(captured)
    try
        Core.eval(session_module(session), :(ans = $(QuoteNode(value))))
    catch
        # If ans update fails (e.g. type not quotable), skip silently.
    end
    push!(session.history, value)
    clamp_history!(session, max_session_history)
    return
end

function handle_message(mw::EvalMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "eval" || return next(msg)
    return eval_responses(ctx, msg; max_repr_bytes=mw.max_repr_bytes)
end
