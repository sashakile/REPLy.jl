"""
    new_session_module(prefix::Symbol) -> Module

Create a fresh anonymous session module (named `##<prefix>#N`) and install a
1-argument `include(path)` wrapper inside it.

Session modules are anonymous, so a bare `include("file.jl")` would otherwise
resolve to `Compiler.include` (wrong signature) and throw `UndefVarError`. The
wrapper delegates to `Base.include(@__MODULE__, path)` so the standard REPL form
`include("file.jl")` loads into the session module as users expect.
"""
function new_session_module(prefix::Symbol)
    mod = Module(gensym(prefix))
    Core.eval(mod, :(include(path::AbstractString) = Base.include(@__MODULE__, path)))
    return mod
end

"""
    ModuleSession

Ephemeral REPL session backed by an anonymous Julia `Module`.
"""
struct ModuleSession
    session_mod::Module
end

@enum EvalLifecycleState EvalQueued EvalRunning EvalCompleted EvalTimedOut
@enum SessionAdmissionOutcome SessionAdmitted SessionNotFound SessionAdmissionQuarantined

"""Per-evaluation lease. Its lock is the authority for deadline/completion,
cancellation delivery, zombie classification, and cleanup ownership."""
mutable struct EvalLifecycle
    lock::ReentrantLock
    request_id::String
    eval_id::Int
    state::EvalLifecycleState
    task::Union{Task,Nothing}
    outcome::Any
    cancel_requested::Bool
    ephemeral_retained::Bool
    zombie_gate_marked::Bool
    setup_ready::Bool
end

EvalLifecycle(request_id::AbstractString) = EvalLifecycle(
    ReentrantLock(), String(request_id), 0, EvalQueued, nothing, nothing,
    false, false, false, false)

"""Request cancellation at most once, publishing ownership under the lifecycle
lock and delivering the exception only after releasing that lock.

Queued work observes `cancel_requested` itself and must not receive an async
exception before it can return its typed admission error. A timeout may opt in
to delivery after atomically changing a formerly-running lifecycle to
`EvalTimedOut`.
"""
function request_eval_cancel!(life::EvalLifecycle; deliver_timed_out::Bool=false)
    task = lock(life.lock) do
        current = life.task
        life.cancel_requested && return nothing
        life.state === EvalTimedOut && !deliver_timed_out && return nothing
        life.cancel_requested = true
        deliver = life.state === EvalRunning ||
                  (deliver_timed_out && life.state === EvalTimedOut)
        if !deliver || isnothing(current) || istaskdone(current::Task)
            return nothing
        end
        current
    end
    isnothing(task) && return false
    try
        schedule(task::Task, InterruptException(); error=true)
        return true
    catch
        return false
    end
end

"""
    session_module(session)

Return the anonymous module that backs `session`.
"""
session_module(session::ModuleSession) = session.session_mod
session_module(::Nothing) = Main

"""
    SessionState

Lifecycle state of a `NamedSession`. Valid transitions via `transition_session_state!`:
- `SessionIdle` → `SessionRunning` (eval starts)
- `SessionRunning` → `SessionIdle` (eval completes or errors)

`SessionClosed` is a terminal state reached only through `destroy_named_session!`.
No transition out of `SessionClosed` is possible.
"""
@enum SessionState begin
    SessionIdle
    SessionRunning
    SessionQuarantined
    SessionDetached
    SessionClosed
end

"""Maximum number of entries kept in each `NamedSession`'s history vector."""
const MAX_SESSION_HISTORY_SIZE = 10_000

"""Maximum number of buffered stdin strings per session before back-pressure applies."""
const MAX_STDIN_BUFFER_SIZE = 256

"""
    StdinFeeder

Encapsulates the persistent per-session stdin Pipe + feeder Task pair. Created
on the first `allow_stdin` eval and torn down when the session is destroyed.

- `pipe` — linked `Base.Pipe` whose `out` end is redirected as the eval's stdin
- `feeder` — `@async` task that reads from `stdin_channel` and writes to `pipe.in`
"""
struct StdinFeeder
    pipe::Base.Pipe
    feeder::Task
end

"""
    NamedSession

Persistent named session with explicit identity, lifecycle state, and activity tracking.
Tracked separately from ephemeral sessions so it can appear in `ls-sessions`
output while ephemeral sessions never do.

The fields `state`, `eval_task`, and `last_active_at` are protected by `session.lock`;
use the provided accessor and transition functions rather than reading or writing them
directly. Evaluation admission is serialized by `eval_queue` and
`running_lifecycle` under `session.lock`. The retained `eval_lock` field is not
part of lifecycle serialization and must not be acquired while holding `session.lock`. The
`stdin_channel` is a bounded `Channel{String}` (capacity `MAX_STDIN_BUFFER_SIZE`) that buffers stdin text across
evals; it is thread-safe and must not be accessed under `session.lock`.

# Lock ownership table

| Field | Protected by | Notes |
|---|---|---|
| `id` | immutable | Set at creation, never changes |
| `name` | immutable | Set at creation, never changes |
| `session_mod` | immutable | Set at creation, never changes |
| `trusted` | immutable | Set at creation, never changes |
| `created_at` | immutable | Set at creation, never changes |
| `state` | `session.lock` | Use `transition_session_state!` / `begin_eval!` / `end_eval!` |
| `eval_task` | `session.lock` | Use `begin_eval!` / `end_eval!` |
| `last_active_at` | `session.lock` | Updated by `begin_eval!` / `end_eval!` |
| `eval_count` | `session.lock` | Incremented by `end_eval!` |
| `eval_id` | `session.lock` | Incremented by `begin_eval!` |
| `history` | unguarded (mutation in eval task only) | `_update_history!` runs inside the eval task; no concurrent access |
| `stdin_channel` | thread-safe `Channel` | Not accessed under `session.lock` |
| `stdin_feeder` | eval lifecycle | Created by the admitted eval; torn down after evaluation |
| `lock` | N/A | The lock itself, not protected by anything |
| `eval_lock` | N/A | Compatibility field only; does not own lifecycle serialization |

# Field documentation

- `id` — canonical UUID string (generated at creation, never changes).
- `name` — optional human-readable alias (may be empty string for unnamed sessions).
- `stdin_feeder` — `StdinFeeder` value (Pipe + feeder Task) or `nothing` if no stdin eval has run yet.
"""

mutable struct NamedSession
    id::String
    name::String
    session_mod::Module
    trusted::Bool
    created_at::Float64
    state::SessionState
    eval_task::Union{Task, Nothing}
    running_lifecycle::Union{EvalLifecycle, Nothing}
    eval_queue::Vector{EvalLifecycle}
    last_active_at::Float64
    lock::ReentrantLock
    eval_lock::ReentrantLock
    stdin_channel::Channel{String}
    history::Vector{Any}
    eval_count::Int
    eval_id::Int
    stdin_feeder::Union{StdinFeeder, Nothing}
end

function NamedSession(id::String, name::String, mod::Module; trusted::Bool=false)
    now = time()
    s = NamedSession(id, name, mod, trusted, now, SessionIdle, nothing, nothing,
                     EvalLifecycle[], now,
                     ReentrantLock(), ReentrantLock(),
                     Channel{String}(MAX_STDIN_BUFFER_SIZE),
                     Any[], 0, 0, nothing)
    return s
end

function teardown_stdin_feeder!(session::NamedSession)
    feeder = session.stdin_feeder
    session.stdin_feeder = nothing
    if !isnothing(feeder)
        if !istaskdone(feeder.feeder)
            schedule(feeder.feeder, InterruptException(); error=true)
        end
        p = feeder.pipe
        isopen(p.in) && close(p.in)
        isopen(p.out) && close(p.out)
    end
    return nothing
end

"""
    clamp_history!(session, max_size)

Drop the oldest entries from `session.history` so it does not exceed
`max_size`. Called after each history push. Does NOT acquire `session.lock`
— caller must ensure exclusive access (currently: called inside the eval task
which is the sole writer to history).
"""
function clamp_history!(session::NamedSession, max_size::Int=MAX_SESSION_HISTORY_SIZE)
    @assert !islocked(session.lock) "clamp_history! must not be called while holding session.lock (called from eval task)"
    excess = length(session.history) - max_size
    excess > 0 && deleteat!(session.history, 1:excess)
    return session
end

"""
    session_id(session)

Return the canonical UUID string that identifies a persistent `NamedSession`.
"""
session_id(session::NamedSession) = session.id

"""
    session_name(session)

Return the optional alias name for a persistent `NamedSession`.
May be an empty string if no alias was provided at creation.
"""
session_name(session::NamedSession) = session.name

"""
    session_module(session)

Return the anonymous module that backs a `NamedSession`.
"""
session_module(session::NamedSession) = session.session_mod

"""
    session_created_at(session)

Return the Unix timestamp (seconds) at which the `NamedSession` was created.
"""
session_created_at(session::NamedSession) = session.created_at

"""
    session_state(session)

Return the current `SessionState` of a `NamedSession`. Thread-safe.
"""
session_state(session::NamedSession) = lock(session.lock) do; session.state; end

"""
    session_eval_task(session)

Return the `Task` currently evaluating in `session`, or `nothing` if idle. Thread-safe.
"""
session_eval_task(session::NamedSession) = lock(session.lock) do; session.eval_task; end

"""
    session_last_active_at(session)

Return the Unix timestamp (seconds) of the most recent activity on `session`. Thread-safe.
"""
session_last_active_at(session::NamedSession) = lock(session.lock) do; session.last_active_at; end

"""
    session_eval_count(session)

Return the number of eval operations that have completed on `session`. Thread-safe.
"""
session_eval_count(session::NamedSession) = lock(session.lock) do; session.eval_count; end

"""
    session_eval_id(session)

Return the monotonic eval ID for the most recently started (or currently running) eval
on `session`. Starts at 0 (no eval has started yet); increments at the *start* of each
eval so the running eval always has a known, stable ID. Thread-safe.
"""
session_eval_id(session::NamedSession) = lock(session.lock) do; session.eval_id; end

"""
    session_module_name(session)

Return the module name for `session`. Returns `"Main"` for trusted sessions,
`"<anonymous>"` for light sessions backed by gensym'd anonymous modules.
"""
session_module_name(s::NamedSession) = s.trusted ? "Main" : "<anonymous>"

"""
    is_trusted(session)

Return `true` if `session` is a trusted session backed by `Main`.
"""
is_trusted(session::NamedSession) = session.trusted

"""
    transition_session_state!(session, new_state)

Transition `session` between `SessionIdle` and `SessionRunning`. Throws `ArgumentError`
for any other edge, including transitions to/from `SessionClosed` (which is terminal
and reachable only through `destroy_named_session!`) and self-transitions.
"""
function transition_session_state!(session::NamedSession, new_state::SessionState)
    lock(session.lock) do
        _transition_state_unlocked!(session, new_state)
    end
    return session
end

# Internal: caller must hold session.lock.
function _transition_state_unlocked!(session::NamedSession, new_state::SessionState)
    current = session.state
    valid = (current === SessionIdle && new_state === SessionRunning) ||
            (current === SessionRunning && new_state === SessionIdle)
    valid || throw(ArgumentError("invalid state transition: $current → $new_state"))
    session.state = new_state
end

"""
    begin_eval!(session, task)

Atomically transition `session` from `SessionIdle` to `SessionRunning`, assign `task`,
and update `last_active_at`. Throws `ArgumentError` if not in `SessionIdle`.

Prefer this over calling `transition_session_state!` and `_set_eval_task!` separately.
"""
function begin_eval!(session::NamedSession, task::Task)
    lock(session.lock) do
        _transition_state_unlocked!(session, SessionRunning)
        session.eval_task = task
        session.last_active_at = time()
        session.eval_id += 1
    end
    return session
end

"""
    end_eval!(session)

Atomically transition `session` from `SessionRunning` to `SessionIdle`, clear the eval
task, and update `last_active_at`. Throws `ArgumentError` if not in `SessionRunning`.

Prefer this over calling `transition_session_state!` and `_set_eval_task!` separately.
"""
function end_eval!(session::NamedSession)
    lock(session.lock) do
        session.state === SessionRunning && (session.state = SessionIdle)
        session.state in (SessionIdle, SessionQuarantined, SessionDetached) ||
            throw(ArgumentError("invalid eval completion state: $(session.state)"))
        session.eval_task = nothing
        session.last_active_at = time()
        session.eval_count += 1
    end
    return session
end

function quarantine_session!(session::NamedSession)
    queued = lock(session.lock) do
        session.state === SessionRunning && (session.state = SessionQuarantined)
        copy(session.eval_queue)
    end
    foreach(request_eval_cancel!, queued)
    return session
end

# Internal: low-level mutators. Use begin_eval!/end_eval! in production code.

_set_eval_task!(session::NamedSession, task::Union{Task, Nothing}) =
    lock(session.lock) do; session.eval_task = task; session; end

_record_activity!(session::NamedSession) =
    lock(session.lock) do; session.last_active_at = time(); session; end
