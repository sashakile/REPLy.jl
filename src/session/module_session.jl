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

"""
    NamedSession

Persistent named session with explicit identity, lifecycle state, and activity tracking.
Tracked separately from ephemeral sessions so it can appear in `ls-sessions`
output while ephemeral sessions never do.

The fields `state`, `eval_task`, and `last_active_at` are protected by `session.lock`;
use the provided accessor and transition functions rather than reading or writing them
directly. The `eval_lock` field is a standalone serialization primitive — it is not
governed by `session.lock` and must not be acquired while holding it.
"""
mutable struct NamedSession
    name::String
    session_mod::Module
    created_at::Float64
    state::SessionState
    eval_task::Union{Task, Nothing}
    last_active_at::Float64
    lock::ReentrantLock
    eval_lock::ReentrantLock
end

function NamedSession(name::String, mod::Module)
    now = time()
    return NamedSession(name, mod, now, SessionIdle, nothing, now, ReentrantLock(), ReentrantLock())
end

"""
    session_name(session)

Return the string name that identifies a persistent `NamedSession`.
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
    end
    return session
end

# Internal: low-level mutators. Use begin_eval!/end_eval! in production code.

_set_eval_task!(session::NamedSession, task::Union{Task, Nothing}) =
    lock(session.lock) do; session.eval_task = task; session; end

_record_activity!(session::NamedSession) =
    lock(session.lock) do; session.last_active_at = time(); session; end
