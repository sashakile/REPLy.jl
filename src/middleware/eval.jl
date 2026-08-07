# Eval middleware — intercepts `op == "eval"` requests, executes code in the
# session module with captured I/O, and returns value/out/err/done messages.
# All other ops are forwarded to the next middleware in the stack.

"""
    EvalMiddleware(; max_repr_bytes=DEFAULT_MAX_REPR_BYTES)

Middleware that handles `op == "eval"` requests. Executes Julia code in the
active session module with captured stdout/stderr, truncates the `repr` of the
return value at `max_repr_bytes`, and returns a sequence of response messages
(out, err, value, done). Passes all other ops to the next middleware.

Named sessions are serialized FIFO by their lifecycle queue. Ephemeral sessions
have no cross-request state and need no serialization.
"""
struct EvalMiddleware <: AbstractMiddleware
    max_repr_bytes::Int
end
EvalMiddleware(; max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES) = EvalMiddleware(max_repr_bytes)
EvalMiddleware(limits::ResourceLimits) = EvalMiddleware(limits.max_value_repr_bytes)

descriptor(::EvalMiddleware) = MiddlewareDescriptor(
    provides = Set(["eval"]),
    requires = Set(["session"]),
    expects  = ["must appear after SessionMiddleware"],
    op_info  = Dict{String, Dict{String, Any}}(
        "eval" => Dict{String, Any}(
            "doc"      => "Evaluate Julia code in a session module.",
            "requires" => ["code"],
            "optional" => ["session", "module", "timeout-ms", "allow-stdin", "silent", "store-history"],
            "returns"  => ["out", "err", "value", "repr-error", "ns", "ephemeral"],
        ),
    ),
)


# Build the terminal `value` response for eval/load-file. On repr success emits
# {value: <repr>, ns}; on repr failure emits {value: null, repr-error: <type>, ns}
# so clients can distinguish a non-representable result from a returned string.
function value_response(request_id::AbstractString, value, module_::Module; max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES)
    kind, payload = try_repr(value; max_bytes=max_repr_bytes)
    if kind === :ok
        return response_message(request_id, "value" => payload, "ns" => string(nameof(module_)))
    else
        return response_message(request_id, "value" => nothing, "repr-error" => payload, "ns" => string(nameof(module_)))
    end
end

function buffered_output_messages(request_id::AbstractString, stdout_text::AbstractString, stderr_text::AbstractString)
    messages = Dict{String, Any}[]
    !isempty(stdout_text) && push!(messages, response_message(request_id, "out" => stdout_text))
    !isempty(stderr_text) && push!(messages, response_message(request_id, "err" => stderr_text))
    return messages
end

function eval_parsed(module_::Module, exprs)
    # Apply REPL soft-scope lowering so top-level loops/blocks that assign to an
    # existing global don't emit the "assignment in soft scope is ambiguous"
    # warning (and error). This matches interactive REPL semantics: assignments
    # still persist to the session module's globals. See REPLy_jl-eka.
    exprs = REPL.softscope(exprs)

    if exprs isa Expr && exprs.head == :toplevel
        value = nothing
        for expr in exprs.args
            value = Core.eval(module_, expr)
        end
        return value
    end

    return Core.eval(module_, exprs)
end

# EvalOutcome — discriminated union for eval results.
#
# Internal representation of what happened during an eval. Serialized to the
# frozen wire format (status arrays, value/err/out messages) at the handler
# boundary via `serialize(...)`, never before.

"""
    EvalOutcome

Discriminated union of eval outcomes. Subtypes carry the data needed to
serialize to wire format at the edge.
"""
abstract type EvalOutcome end

"""
    Completed(value, stdout, stderr)

Eval finished normally. `value` is the evaluated result (may be `nothing` for
empty code). `stdout` and `stderr` are captured output.
"""
struct Completed <: EvalOutcome
    value::Any
    stdout::String
    stderr::String
end

"""
    Interrupted(stdout, stderr)

Eval was interrupted by `InterruptException` (interrupt op). `stdout` and
`stderr` are any output captured before the interrupt.
"""
struct Interrupted <: EvalOutcome
    stdout::String
    stderr::String
end

"""
    TimedOut(timeout_ms, stdout, stderr)

Eval exceeded the configured timeout. `timeout_ms` is the effective timeout
that fired. `stdout` and `stderr` are any output captured before timeout.
"""
struct TimedOut <: EvalOutcome
    timeout_ms::Int
    stdout::String
    stderr::String
end

"""
    Errored(exception, backtrace, stdout, stderr)

Eval threw an exception. `stdout` and `stderr` are any output captured
before the error.
"""
struct Errored <: EvalOutcome
    exception::Any
    backtrace::Any
    stdout::String
    stderr::String
end

"""
    Cancelled(reason)

Eval was cancelled before execution (e.g. session closed).
"""
struct Cancelled <: EvalOutcome
    reason::String
end

"""
    _run_eval_core(module_, request_id, code, max_repr_bytes; silent, max_output_bytes) -> EvalOutcome

Core evaluation logic. Captures stdout/stderr, parses and evaluates code, and
returns a typed `EvalOutcome` discriminated union instead of raw wire-format
messages. Serialization to the wire format happens at the handler boundary.
"""
function _run_eval_core(module_::Module, request_id::AbstractString, code::AbstractString, max_repr_bytes::Int; silent::Bool=false, max_output_bytes::Int=typemax(Int))::EvalOutcome
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
            if isempty(strip(code))
                (:ok, nothing)
            else
                (:ok, eval_parsed(module_, Meta.parseall(code)))
            end
        catch ex
            (:error, ex, catch_backtrace())
        end

        stdout_text = truncate_output(String(take!(stdout_buf)), max_output_bytes)
        stderr_text = truncate_output(String(take!(stderr_buf)), max_output_bytes)

        if first(eval_result) === :error
            _, ex, bt = eval_result
            if ex isa InterruptException
                return Interrupted(stdout_text, stderr_text)
            else
                return Errored(ex, bt, stdout_text, stderr_text)
            end
        end

        _, value = eval_result
        return Completed(value, stdout_text, stderr_text)
    finally
        unregister_task_capture!(stdout_cap, task)
        unregister_task_capture!(stderr_cap, task)
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

# Create (or return existing) persistent stdin Pipe + feeder Task for `session`.
# Called only by the lifecycle admitted as the session's running eval.
function _ensure_stdin_feeder!(session::NamedSession)
    isnothing(session.stdin_feeder) || return session.stdin_feeder::StdinFeeder
    pipe = Base.Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
    feeder = @async _stdin_feeder(session.stdin_channel, pipe.in)
    sf = StdinFeeder(pipe, feeder)
    session.stdin_feeder = sf
    return sf
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

"""
    serialize(outcome, request_id, module_; kwargs...) -> Vector{Dict}

Serialize an `EvalOutcome` to the frozen wire format. This is the ONLY place
where wire-format messages are constructed — internal code works with
`EvalOutcome` values exclusively.

Keyword arguments add edge-only metadata:
- `max_repr_bytes`: truncation limit for `repr` of value
- `silent`: when true, omit the `value` response frame
- `eval_id`: eval sequence number for named sessions (added to terminal frame)
- `ephemeral`: when true, mark terminal frame with `ephemeral: true`
"""
function serialize(outcome::Completed, request_id::AbstractString, module_::Module;
    max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES, silent::Bool=false,
    eval_id=nothing, ephemeral::Bool=false)

    msgs = buffered_output_messages(request_id, outcome.stdout, outcome.stderr)
    if !silent
        push!(msgs, value_response(request_id, outcome.value, module_; max_repr_bytes=max_repr_bytes))
    end
    terminal = done_response(request_id)
    if !isnothing(eval_id)
        terminal["eval-id"] = eval_id
    end
    if ephemeral
        terminal["ephemeral"] = true
    end
    push!(msgs, terminal)
    return msgs
end

function serialize(outcome::Interrupted, request_id::AbstractString, module_::Module;
    max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES, silent::Bool=false,
    eval_id=nothing, ephemeral::Bool=false)

    msgs = buffered_output_messages(request_id, outcome.stdout, outcome.stderr)
    terminal = response_message(request_id, "status" => ["done", "interrupted"])
    if !isnothing(eval_id)
        terminal["eval-id"] = eval_id
    end
    if ephemeral
        terminal["ephemeral"] = true
    end
    push!(msgs, terminal)
    return msgs
end

function serialize(outcome::TimedOut, request_id::AbstractString, module_::Module;
    max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES, silent::Bool=false,
    eval_id=nothing, ephemeral::Bool=false)

    msgs = buffered_output_messages(request_id, outcome.stdout, outcome.stderr)
    terminal = timeout_response(request_id, outcome.timeout_ms)
    if !isnothing(eval_id)
        terminal["eval-id"] = eval_id
    end
    if ephemeral
        terminal["ephemeral"] = true
    end
    push!(msgs, terminal)
    return msgs
end

function serialize(outcome::Errored, request_id::AbstractString, module_::Module;
    max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES, silent::Bool=false,
    eval_id=nothing, ephemeral::Bool=false)

    msgs = buffered_output_messages(request_id, outcome.stdout, outcome.stderr)
    terminal = eval_error_response(request_id, outcome.exception; bt=outcome.backtrace)
    if !isnothing(eval_id)
        terminal["eval-id"] = eval_id
    end
    if ephemeral
        terminal["ephemeral"] = true
    end
    push!(msgs, terminal)
    return msgs
end

function serialize(outcome::Cancelled, request_id::AbstractString, ::Module;
    max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES, silent::Bool=false,
    eval_id=nothing, ephemeral::Bool=false)

    return [error_response(request_id, outcome.reason)]
end

"""
    run_with_timeout(task, effective_timeout_ms, request_id) -> EvalOutcome

Wait for a scheduled `Task` that returns an `EvalOutcome`. If the timeout fires
before the task finishes, returns a `TimedOut` outcome. The timeout timer sends
`InterruptException` to the task; if the task is not interruptible (ccall, BLAS),
the bounded wait expires and returns timeout.

When `effective_timeout_ms` is `nothing`, fetches the task directly with no timer
— but still catches `InterruptException` from the interrupt middleware.
"""
function run_with_timeout(task::Task, ::Nothing, request_id::AbstractString)
    try
        result = fetch(task)
        return result isa EvalOutcome ? result : Interrupted("", "")
    catch ex
        inner = ex isa TaskFailedException ? ex.task.exception : ex
        inner isa InterruptException || rethrow()
        return Interrupted("", "")
    end
end

function run_with_timeout(task::Task, timeout_ms::Int, request_id::AbstractString)
    timed_out = Ref(false)

    timeout_timer = Timer(timeout_ms / 1000.0) do _
        istaskdone(task) && return
        timed_out[] = true
        try
            schedule(task, InterruptException(); error=true)
        catch
        end
    end

    try
        while !istaskdone(task) && !timed_out[]
            yield()
            sleep(0.01)
        end

        if timed_out[]
            if istaskdone(task)
                result = fetch(task)
                if result isa Interrupted
                    # Task finished with Interrupted — convert to TimedOut,
                    # preserving captured stdout/stderr.
                    return TimedOut(timeout_ms, result.stdout, result.stderr)
                end
            end
            return TimedOut(timeout_ms, "", "")
        else
            result = fetch(task)
            return result isa EvalOutcome ? result : Interrupted("", "")
        end
    catch ex
        inner = ex isa TaskFailedException ? ex.task.exception : ex
        inner isa InterruptException || rethrow()
        if timed_out[]
            return TimedOut(timeout_ms, "", "")
        else
            return Interrupted("", "")
        end
    finally
        close(timeout_timer)
    end
end

function timeout_response(request_id::AbstractString, effective_timeout_ms)
    return response_message(
        request_id,
        "status" => ["done", "error", "timeout"],
        "err" => isnothing(effective_timeout_ms) ? "eval timed out" : "eval timed out after $(effective_timeout_ms) ms",
        "max-eval-time-ms" => effective_timeout_ms,
        "hint" => "eval exceeded max_eval_time_ms; raise the max_eval_time_ms resource limit to allow longer evaluations",
    )
end

function _register_named_lifecycle!(session::NamedSession, life::EvalLifecycle)
    lock(session.lock) do
        session.state === SessionQuarantined && return SessionAdmissionQuarantined
        session.state in (SessionClosed, SessionDetached) && return SessionNotFound
        push!(session.eval_queue, life)
        return SessionAdmitted
    end
end

function _remove_named_lifecycle!(session::NamedSession, life::EvalLifecycle)
    lock(session.lock) do
        filter!(queued -> queued !== life, session.eval_queue)
        return session.state === SessionDetached &&
               isnothing(session.running_lifecycle) && isempty(session.eval_queue)
    end
end

function _remove_and_finish_named_lifecycle!(manager::SessionManager,
                                             session::NamedSession,
                                             life::EvalLifecycle)
    _remove_named_lifecycle!(session, life) && finish_detached_session!(manager, session)
    return nothing
end

function _current_session_admission(session::NamedSession)
    lock(session.lock) do
        session.state === SessionQuarantined ? SessionAdmissionQuarantined :
        session.state in (SessionClosed, SessionDetached) ? SessionNotFound : SessionAdmitted
    end
end

function _enter_named_eval!(session::NamedSession, life::EvalLifecycle)
    while true
        admitted = lock(session.lock) do
            lock(life.lock) do
                if life.state === EvalTimedOut
                    # The request handler already owns the timeout response. The
                    # child must stop here rather than execute code after its deadline.
                    return SessionNotFound
                elseif session.state === SessionQuarantined
                    return SessionAdmissionQuarantined
                elseif life.cancel_requested || session.state in (SessionClosed, SessionDetached)
                    return SessionNotFound
                end
                if isnothing(session.running_lifecycle) && first(session.eval_queue) === life
                    popfirst!(session.eval_queue)
                    session.eval_id += 1
                    life.eval_id = session.eval_id
                    session.running_lifecycle = life
                    session.eval_task = life.task
                    session.state = SessionRunning
                    session.last_active_at = time()
                    life.state = EvalRunning
                    return SessionAdmitted
                end
                nothing
            end
        end
        !isnothing(admitted) && return admitted
        sleep(0.002)
    end
end

function _session_admission_response(outcome::SessionAdmissionOutcome,
                                     request_id::AbstractString, session::NamedSession)
    outcome === SessionAdmissionQuarantined && return [session_quarantined_response(request_id)]
    return [session_not_found_response(request_id, session.name)]
end

function _observe_eval_completion!(life::EvalLifecycle, session, manager, state)
    task = life.task::Task
    outcome = try
        fetch(task)
    catch ex
        inner = ex isa TaskFailedException ? ex.task.exception : ex
        inner isa InterruptException ? Interrupted("", "") : Errored(inner, catch_backtrace(), "", "")
    end
    lock(life.lock) do
        life.outcome = outcome
        life.state === EvalTimedOut || (life.state = EvalCompleted)
    end
    # A deadline winner owns timeout setup. Do not inspect zombie ownership
    # until it has either installed accounting or published setup failure.
    while lock(life.lock) do; life.state === EvalTimedOut && !life.setup_ready; end
        # Poll retained lifecycle state rather than blocking on a wake token that
        # may have been consumed by an earlier queue/admission transition.
        yield()
        sleep(0.001)
    end
    ephemeral_retained, zombie_gate_marked = lock(life.lock) do
        (life.ephemeral_retained, life.zombie_gate_marked)
    end
    try
        if session isa NamedSession
            detached = lock(session.lock) do
                # Completion owns identity cleanup even when interruption killed
                # the task while it was still waiting in _enter_named_eval!.
                filter!(queued -> queued !== life, session.eval_queue)
                if session.running_lifecycle === life
                    session.running_lifecycle = nothing
                    session.eval_task = nothing
                    if session.state === SessionRunning
                        session.state = SessionIdle
                        session.eval_count += 1
                        session.last_active_at = time()
                    end
                end
                session.state === SessionDetached &&
                    isnothing(session.running_lifecycle) && isempty(session.eval_queue)
            end
            detached && try finish_detached_session!(manager, session) catch end
        elseif ephemeral_retained
            try finish_retained_ephemeral!(manager, session) catch end
        end
    finally
        if !isnothing(state)
            try unregister_active_eval!(state, task) finally
                zombie_gate_marked ? release_zombie!(state.gate) : release!(state.gate)
            end
        end
    end
    nothing
end

# Narrow test seam for failures between registry admission and task startup.
const _EVAL_TASK_SCHEDULER = Ref{Function}(schedule)
const _TIMEOUT_SETUP_HOOK = Ref{Function}(() -> nothing)

function eval_responses(ctx::RequestContext, req::EvalRequest; max_repr_bytes::Int=DEFAULT_MAX_REPR_BYTES)
    request_id = req.id
    code = req.code
    timeout_ms = req.timeout_ms
    silent = req.silent
    allow_stdin = req.allow_stdin
    store_history = req.store_history

    # Effective timeout: per-request value capped at server max, or server max alone.
    max_eval_time = effective_limit(ctx.server_state, :max_eval_time_ms, nothing)
    effective_timeout_ms = if !isnothing(timeout_ms) && !isnothing(max_eval_time)
        min(Int(timeout_ms), max_eval_time)
    elseif !isnothing(timeout_ms)
        Int(timeout_ms)
    elseif !isnothing(max_eval_time)
        max_eval_time
    else
        nothing
    end

    max_output_bytes    = effective_limit(ctx.server_state, :max_output_bytes, typemax(Int))
    max_session_history = effective_limit(ctx.server_state, :max_history_entries, MAX_SESSION_HISTORY_SIZE)

    life = EvalLifecycle(request_id)
    session = ctx.session
    if session isa NamedSession
        admission = _register_named_lifecycle!(session, life)
        admission === SessionAdmitted ||
            return _session_admission_response(admission, request_id, session)
    end

    # Concurrent eval slot acquisition via EvalGate (spec REQ-RPL-047d).
    state = ctx.server_state
    if !isnothing(state)
        if !acquire!(state.gate, life)
            if session isa NamedSession
                _remove_and_finish_named_lifecycle!(ctx.manager, session, life)
                admission = _current_session_admission(session)
                admission === SessionAdmitted ||
                    return _session_admission_response(admission, request_id, session)
            end
            if state.shutdown_requested[]
                return [error_response(request_id, "server is shutting down";
                    status_flags=String["error", "shutdown"])]
            end
            return [error_response(request_id, "Too many concurrent evals";
                status_flags=String["error", "concurrency-limit-reached"])]
        end
    end

    this_eval_id = Ref{Union{Int, Nothing}}(nothing)
    eval_module_ref = Ref{Union{Module, Nothing}}(nothing)

    # Run the eval body on a DEDICATED child task.
    eval_task = @task begin
        admission = session isa NamedSession ? _enter_named_eval!(session, life) : SessionAdmitted
        if admission !== SessionAdmitted
            admission
        else
            eval_module = session_module(session)
            eval_module_ref[] = eval_module
            module_path = req.module_path
            if module_path isa AbstractString
                resolved = resolve_module(module_path)
                if isnothing(resolved)
                    return Cancelled("Cannot resolve module: $(module_path)")
                end
                eval_module = resolved
            end

            if session isa NamedSession
                this_eval_id[] = life.eval_id
                revise_enabled = effective_limit(ctx.server_state, :revise_hook_enabled, true)
                revise_enabled && _maybe_revise!()
            end

            outcome = if allow_stdin && session isa NamedSession
                sf = _ensure_stdin_feeder!(session)
                redirect_stdin(sf.pipe.out) do
                    _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent, max_output_bytes)
                end
            elseif allow_stdin
                _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent, max_output_bytes)
            else
                redirect_stdin(devnull) do
                    _run_eval_core(eval_module, request_id, code, max_repr_bytes; silent, max_output_bytes)
                end
            end

            session isa NamedSession && _update_history!(session, outcome, store_history, max_session_history)
            outcome
        end
    end
    eval_task.sticky = true
    lock(life.lock) do
        life.task = eval_task
        !(session isa NamedSession) && (life.state = EvalRunning)
    end
    permit_owned = !isnothing(state)
    registered = false
    observer_started = false
    timeout_was_running = Ref(false)
    try
        if !isnothing(state) && !register_active_eval!(state, eval_task, life)
            return [error_response(request_id, "server is shutting down";
                status_flags=String["error", "shutdown"])]
        end
        registered = !isnothing(state)
        _EVAL_TASK_SCHEDULER[](eval_task)
        @async _observe_eval_completion!(life, session, ctx.manager, state)
        observer_started = true

        deadline = isnothing(effective_timeout_ms) ? Inf : time() + effective_timeout_ms / 1000
        outcome = nothing
        while isnothing(outcome)
            outcome = lock(life.lock) do
                if life.state === EvalCompleted
                    return life.outcome
                elseif life.state === EvalTimedOut
                    return TimedOut(something(effective_timeout_ms, typemax(Int)), "", "")
                elseif time() >= deadline
                    # Completion and deadline classify under this one lock. A running
                    # task that is live at the winning deadline is quarantined first.
                    if istaskdone(eval_task)
                        return nothing # observer will publish the actual outcome
                    end
                    was_running = life.state === EvalRunning
                    life.state = EvalTimedOut
                    if was_running
                        timeout_was_running[] = true
                    end
                    return TimedOut(something(effective_timeout_ms, typemax(Int)), "", "")
                end
                nothing
            end
            isnothing(outcome) || break
            sleep(0.002)
        end

        if outcome isa TimedOut
            try
                try
                    _TIMEOUT_SETUP_HOOK[]()
                catch ex
                    @warn "timeout setup hook failed; continuing lifecycle quarantine" exception=(ex, catch_backtrace())
                end
                if timeout_was_running[]
                    if session isa NamedSession
                        quarantine_session!(session)
                    else
                        if session isa ModuleSession
                            retain_ephemeral!(ctx.manager, session)
                            lock(life.lock) do; life.ephemeral_retained = true; end
                        end
                    end
                    if !isnothing(state)
                        mark_zombie!(state.gate)
                        lock(life.lock) do; life.zombie_gate_marked = true; end
                    end
                end
            finally
                lock(life.lock) do
                    life.setup_ready = true
                end
                request_eval_cancel!(life; deliver_timed_out=timeout_was_running[])
            end
        end

        # Serialize EvalOutcome to wire format at the edge.
        if outcome isa SessionAdmissionOutcome
            return _session_admission_response(outcome, request_id, session::NamedSession)
        end
        eid = life.eval_id == 0 ? nothing : life.eval_id
        ephemeral_flag = !(ctx.session isa NamedSession)
        response_module = something(eval_module_ref[], session_module(session))
        msgs = serialize(outcome, request_id, response_module;
            max_repr_bytes=max_repr_bytes,
            silent=silent,
            eval_id=eid,
            ephemeral=ephemeral_flag,
        )

        return msgs
    finally
        # Once started, the observer owns registry and permit cleanup. Before
        # that handoff, this admission owns exactly the permit it acquired.
        if !observer_started
            lock(life.lock) do
                life.setup_ready = true
            end
            session isa NamedSession &&
                _remove_and_finish_named_lifecycle!(ctx.manager, session, life)
            registered && unregister_active_eval!(state::ServerState, eval_task)
            permit_owned && release!((state::ServerState).gate)
        end
    end
end

# Update ans binding and history for `session` when `store_history` is true
# and the outcome is `Completed` (successful eval). Does nothing on error.
function _update_history!(session::NamedSession, outcome::EvalOutcome, store_history::Bool, max_session_history::Int=MAX_SESSION_HISTORY_SIZE)
    store_history && outcome isa Completed || return
    value = outcome.value
    # QuoteNode throws MethodError for non-quotable types (e.g. Task, IOStream).
    # Catch that specific case and skip silently; rethrow anything unexpected.
    try
        Core.eval(session_module(session), :(ans = $(QuoteNode(value))))
    catch ex
        if ex isa MethodError || ex isa ErrorException
            @debug "ans update skipped" value_type=typeof(value) exception_type=typeof(ex)
            return
        end
        rethrow()
    end
    push!(session.history, value)
    clamp_history!(session, max_session_history)
    return
end

function handle_message(mw::EvalMiddleware, msg, next, ctx::RequestContext)
    get(msg, "op", nothing) == "eval" || return next(msg)
    req = try
        parse_eval_request(msg)
    catch ex
        ex isa ArgumentError || rethrow()
        return [error_response(String(get(msg, "id", "")), ex.msg;
                    status_flags=String["error", "invalid-request"])]
    end
    return eval_responses(ctx, req; max_repr_bytes=mw.max_repr_bytes)
end
