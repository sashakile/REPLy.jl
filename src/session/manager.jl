"""
    SessionManager

Track ephemeral `ModuleSession`s and persistent `NamedSession`s separately.

- `ephemeral_sessions` — short-lived sessions created per eval request;
  `session_count` reflects this vector for leak detection.
- `named_sessions` — persistent sessions keyed by name; the only sessions
  that appear in `ls-sessions` output.

The invariant that ephemeral sessions never appear in `list_named_sessions`
is enforced by keeping the two registries strictly separate.
"""
mutable struct SessionManager
    lock::ReentrantLock
    ephemeral_sessions::Vector{ModuleSession}
    named_sessions::Dict{String,NamedSession}
end

SessionManager() = SessionManager(ReentrantLock(), ModuleSession[], Dict{String,NamedSession}())

"""
    create_ephemeral_session!(manager)

Create and register a new ephemeral session backed by an anonymous module.
"""
function create_ephemeral_session!(manager::SessionManager)
    lock(manager.lock) do
        session = ModuleSession(Module(gensym(:REPLySession)))
        push!(manager.ephemeral_sessions, session)
        return session
    end
end

"""
    destroy_session!(manager, session)

Remove `session` from `manager`. This operation is idempotent so cleanup code
can call it safely from both success and error paths.
"""
function destroy_session!(manager::SessionManager, session::ModuleSession)
    lock(manager.lock) do
        filter!(existing -> existing !== session, manager.ephemeral_sessions)
    end
    return nothing
end

"""
    session_count(manager)

Return the number of registered ephemeral sessions. Named sessions are not
counted here; use `length(list_named_sessions(manager))` for those.
"""
session_count(manager::SessionManager) = lock(manager.lock) do
    length(manager.ephemeral_sessions)
end

"""
    create_named_session!(manager, name)

Create and register a persistent named session. The session is keyed by
`name` and will appear in `list_named_sessions` output.

If a session with `name` already exists it is silently replaced — the old
module and its bindings become unreachable via the registry.

Name validation (e.g. rejecting empty strings) is the caller's responsibility.
"""
function create_named_session!(manager::SessionManager, name::AbstractString)
    lock(manager.lock) do
        session = NamedSession(String(name), Module(gensym(:REPLyNamedSession)))
        manager.named_sessions[session.name] = session
        return session
    end
end

"""
    list_named_sessions(manager)

Return all registered persistent named sessions. Ephemeral sessions are
never included — this is the authoritative source for `ls-sessions`.
"""
list_named_sessions(manager::SessionManager) = lock(manager.lock) do
    collect(values(manager.named_sessions))
end

"""
    lookup_named_session(manager, name)

Return the `NamedSession` registered under `name`, or `nothing` if no such
session exists.
"""
function lookup_named_session(manager::SessionManager, name::AbstractString)
    lock(manager.lock) do
        get(manager.named_sessions, String(name), nothing)
    end
end

"""
    destroy_named_session!(manager, name)

Remove the named session registered under `name`. This operation is
idempotent — calling it when no such session exists is safe.
"""
function destroy_named_session!(manager::SessionManager, name::AbstractString)
    lock(manager.lock) do
        session = get(manager.named_sessions, String(name), nothing)
        if !isnothing(session)
            # Transition to terminal state under session.lock before removing from the dict.
            # Lock order: manager.lock (outer) → session.lock (inner).
            lock(session.lock) do
                session.state = SessionClosed
            end
            delete!(manager.named_sessions, String(name))
        end
    end
    return nothing
end

"""
    try_begin_eval!(session, task) -> Bool

Attempt to atomically transition `session` from `SessionIdle` to `SessionRunning`,
assign `task`, and update `last_active_at`. Returns `true` on success.

Returns `false` (without throwing) if the session is in `SessionClosed`, making
this safe to call after a concurrent `destroy_named_session!` without a separate
closed-session check.

Throws `ArgumentError` for `SessionRunning` — callers must hold `session.eval_lock`
to prevent double-acquisition, which is the only way this state can occur here.
"""
function try_begin_eval!(session::NamedSession, task::Task)
    lock(session.lock) do
        session.state === SessionClosed && return false
        _transition_state_unlocked!(session, SessionRunning)
        session.eval_task = task
        session.last_active_at = time()
        return true
    end
end

"""
    sweep_idle_sessions!(manager; max_idle_seconds) -> Vector{String}

Destroy all `SessionIdle` named sessions whose `last_active_at` is more than
`max_idle_seconds` seconds in the past. Running and closed sessions are skipped.

Returns the names of the sessions that were removed, in the order they were swept.

Runs in three phases to avoid TOCTOU races:
1. Snapshot session references under `manager.lock` (no session locks held).
2. Check state under each `session.lock` alone (manager is unblocked during this).
3. Re-acquire both locks per candidate; re-verify identity and state before destroying.

Phase 3 is necessary because a session can be recreated under the same name
(invalidating identity) or transitioned to `SessionRunning` (invalidating state)
between phases 1/2 and the actual destruction.
"""
function sweep_idle_sessions!(manager::SessionManager; max_idle_seconds::Real)
    max_idle_seconds > 0 || throw(ArgumentError("max_idle_seconds must be positive, got $max_idle_seconds"))
    cutoff = time() - max_idle_seconds

    # Phase 1: snapshot (name → session_ref) pairs while holding manager.lock.
    # No session locks acquired here to minimise blocking time.
    snapshots = lock(manager.lock) do; collect(manager.named_sessions); end

    # Phase 2: filter candidates under session.lock only — manager is unblocked.
    candidates = [(name, s) for (name, s) in snapshots
                  if lock(s.lock) do; s.state === SessionIdle && s.last_active_at < cutoff; end]

    # Phase 3: atomically re-verify and destroy each candidate.
    # Lock order: manager.lock (outer) → session.lock (inner) — matches destroy_named_session!.
    removed = String[]
    for (name, session_ref) in candidates
        destroyed = lock(manager.lock) do
            # Identity check: reject if a new session was created under the same name.
            get(manager.named_sessions, name, nothing) === session_ref || return false
            lock(session_ref.lock) do
                # State check: reject if the session became active since phase 2.
                session_ref.state === SessionIdle || return false
                session_ref.state = SessionClosed
            end
            delete!(manager.named_sessions, name)
            return true
        end
        destroyed && push!(removed, name)
    end
    return removed
end

"""
    clone_named_session!(manager, source_name, dest_name)

Create a new named session `dest_name` by copying the module bindings from
the session registered under `source_name`. The clone gets its own anonymous
module so mutations in the clone do not affect the original.

Returns the new `NamedSession`, or `nothing` if `source_name` is not found.

Throws `ArgumentError` if `dest_name` already exists — callers must check
or close the existing session first.
"""
function clone_named_session!(manager::SessionManager, source_name::AbstractString, dest_name::AbstractString)
    # Hold the lock only for the structural dict operations. The binding copy
    # (deepcopy + Core.eval) runs outside the lock so it does not block other
    # tasks for the duration of potentially slow copies.
    source, dest = lock(manager.lock) do
        src = get(manager.named_sessions, String(source_name), nothing)
        isnothing(src) && return (nothing, nothing)

        if haskey(manager.named_sessions, String(dest_name))
            throw(ArgumentError("session already exists: $(dest_name)"))
        end

        dst = NamedSession(String(dest_name), Module(gensym(:REPLyNamedSession)))
        manager.named_sessions[dst.name] = dst
        (src, dst)
    end

    (isnothing(source) || isnothing(dest)) && return nothing

    source_mod = session_module(source)
    dest_mod = session_module(dest)

    # Copy all user-defined bindings from source module to destination module.
    # We skip names that start with '#' (gensym'd module name) and 'eval'/'include'
    # which are auto-defined in every module.
    for sym in names(source_mod; all=true)
        sym in (:eval, :include) && continue
        startswith(String(sym), "#") && continue
        if isdefined(source_mod, sym)
            val = getfield(source_mod, sym)
            val isa Module && continue
            copied = ismutable(val) ? deepcopy(val) : val
            Core.eval(dest_mod, :($(sym) = $(QuoteNode(copied))))
        end
    end

    return dest
end
