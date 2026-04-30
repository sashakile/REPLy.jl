"""
    ModuleSession

Ephemeral REPL session backed by an anonymous Julia `Module`.
"""
struct ModuleSession
    session_mod::Module
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
    SessionClosed
end

"""Maximum number of entries kept in each `NamedSession`'s history vector."""
const MAX_SESSION_HISTORY_SIZE = 1000

"""Maximum number of buffered stdin strings per session before back-pressure applies."""
const MAX_STDIN_BUFFER_SIZE = 256

"""
    NamedSession

Persistent named session with explicit identity, lifecycle state, and activity tracking.
Tracked separately from ephemeral sessions so it can appear in `ls-sessions`
output while ephemeral sessions never do.

The fields `state`, `eval_task`, and `last_active_at` are protected by `session.lock`;
use the provided accessor and transition functions rather than reading or writing them
directly. The `eval_lock` field is a standalone serialization primitive — it is not
governed by `session.lock` and must not be acquired while holding it. The
`stdin_channel` is a bounded `Channel{String}` (capacity `MAX_STDIN_BUFFER_SIZE`) that buffers stdin text across
evals; it is thread-safe and must not be accessed under `session.lock`.

- `id` — canonical UUID string (generated at creation, never changes).
- `name` — optional human-readable alias (may be empty string for unnamed sessions).
"""

mutable struct NamedSession
    id::String
    name::String
    session_mod::Module
    created_at::Float64
    state::SessionState
    eval_task::Union{Task, Nothing}
    last_active_at::Float64
    lock::ReentrantLock
    eval_lock::ReentrantLock
    stdin_channel::Channel{String}
    history::Vector{Any}
    eval_count::Int
    eval_id::Int
end

function NamedSession(id::String, name::String, mod::Module)
    now = time()
    s = NamedSession(id, name, mod, now, SessionIdle, nothing, now, ReentrantLock(), ReentrantLock(), Channel{String}(MAX_STDIN_BUFFER_SIZE), Any[], 0, 0)
    return s
end

"""
    clamp_history!(session, max_size=MAX_SESSION_HISTORY_SIZE)

Drop the oldest entries from `session.history` so it does not exceed
`max_size`. Called after each history push.
"""
function clamp_history!(session::NamedSession, max_size::Int=MAX_SESSION_HISTORY_SIZE)
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

Return the module name for `session`. Always `"<anonymous>"` for light sessions,
since they are backed by gensym'd anonymous modules.
"""
session_module_name(::NamedSession) = "<anonymous>"

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
        _transition_state_unlocked!(session, SessionIdle)
        session.eval_task = nothing
        session.last_active_at = time()
        session.eval_count += 1
    end
    return session
end

# Internal: low-level mutators. Use begin_eval!/end_eval! in production code.

_set_eval_task!(session::NamedSession, task::Union{Task, Nothing}) =
    lock(session.lock) do; session.eval_task = task; session; end

_record_activity!(session::NamedSession) =
    lock(session.lock) do; session.last_active_at = time(); session; end
