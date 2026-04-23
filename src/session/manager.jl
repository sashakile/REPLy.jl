using UUIDs: uuid4

"""
    SessionManager

Track ephemeral `ModuleSession`s and persistent `NamedSession`s separately.

- `ephemeral_sessions` — short-lived sessions created per eval request;
  `session_count` reflects this vector for leak detection.
- `named_sessions` — persistent sessions keyed by UUID; the only sessions
  that appear in `ls-sessions` output.
- `name_to_uuid` — optional alias-to-UUID index; allows callers to look up
  sessions by human-readable name in addition to canonical UUID.

The invariant that ephemeral sessions never appear in `list_named_sessions`
is enforced by keeping the two registries strictly separate.
"""
mutable struct SessionManager
    lock::ReentrantLock
    ephemeral_sessions::Vector{ModuleSession}
    named_sessions::Dict{String,NamedSession}
    name_to_uuid::Dict{String,String}
end

SessionManager() = SessionManager(ReentrantLock(), ModuleSession[], Dict{String,NamedSession}(), Dict{String,String}())

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
    total_session_count(manager)

Return the total number of active sessions: ephemeral + named.
Used for `max_sessions` enforcement.
"""
total_session_count(manager::SessionManager) = lock(manager.lock) do
    length(manager.ephemeral_sessions) + length(manager.named_sessions)
end

"""
    create_named_session!(manager, name; id=nothing)

Create and register a persistent named session. The session is keyed by its
UUID in `named_sessions` and will appear in `list_named_sessions` output.
If `name` is non-empty it is also registered in `name_to_uuid` as an alias.

If a session with the same `name` alias already exists, the old alias mapping
is removed before registering the new one — the old session remains accessible
by its UUID until explicitly destroyed.

If a session with the same `id` already exists it is silently replaced.

Name and id validation is the caller's responsibility.
An explicit `id` may be supplied (for testing); otherwise a fresh UUID is generated.
"""
function create_named_session!(manager::SessionManager, name::AbstractString; id::Union{Nothing,AbstractString}=nothing)
    lock(manager.lock) do
        uuid = isnothing(id) ? string(uuid4()) : String(id)
        session = NamedSession(uuid, String(name), Module(gensym(:REPLyNamedSession)))
        # Remove the old session if a different session held this name alias.
        old_uuid = get(manager.name_to_uuid, String(name), nothing)
        if !isnothing(old_uuid) && old_uuid != uuid
            old_session = get(manager.named_sessions, old_uuid, nothing)
            if !isnothing(old_session)
                lock(old_session.lock) do
                    old_session.state = SessionClosed
                end
            end
            delete!(manager.named_sessions, old_uuid)
            delete!(manager.name_to_uuid, String(name))
        end
        manager.named_sessions[uuid] = session
        if !isempty(name)
            manager.name_to_uuid[String(name)] = uuid
        end
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
    lookup_named_session(manager, id_or_name)

Return the `NamedSession` registered under the given UUID or name alias,
or `nothing` if no such session exists.

Resolution order:
1. Try `id_or_name` as a UUID key in `named_sessions`.
2. Try `id_or_name` as a name alias in `name_to_uuid`, then look up the UUID.
"""
function lookup_named_session(manager::SessionManager, id_or_name::AbstractString)
    lock(manager.lock) do
        key = String(id_or_name)
        # Direct UUID lookup first.
        s = get(manager.named_sessions, key, nothing)
        isnothing(s) || return s
        # Fall back to alias lookup.
        uuid = get(manager.name_to_uuid, key, nothing)
        isnothing(uuid) ? nothing : get(manager.named_sessions, uuid, nothing)
    end
end

"""
    destroy_named_session!(manager, id_or_name) -> Bool

Remove the named session identified by UUID or name alias. Returns `true` if a
session was removed, `false` if no such session existed. This operation is
idempotent — calling it when no such session exists is safe.
"""
function destroy_named_session!(manager::SessionManager, id_or_name::AbstractString)
    lock(manager.lock) do
        key = String(id_or_name)
        # Resolve to UUID.
        uuid, session = _resolve_to_uuid_and_session(manager, key)
        isnothing(session) && return false
        # Transition to terminal state under session.lock before removing from the dict.
        # Lock order: manager.lock (outer) → session.lock (inner).
        lock(session.lock) do
            session.state = SessionClosed
        end
        delete!(manager.named_sessions, uuid)
        # Clean up the alias mapping if the name still points to this UUID.
        name = session.name
        if !isempty(name) && get(manager.name_to_uuid, name, nothing) == uuid
            delete!(manager.name_to_uuid, name)
        end
        return true
    end
end

# Internal: resolve id_or_name to (uuid, session) under manager.lock.
# Returns (nothing, nothing) if not found.
function _resolve_to_uuid_and_session(manager::SessionManager, key::String)
    s = get(manager.named_sessions, key, nothing)
    !isnothing(s) && return (key, s)
    uuid = get(manager.name_to_uuid, key, nothing)
    isnothing(uuid) && return (nothing, nothing)
    s2 = get(manager.named_sessions, uuid, nothing)
    isnothing(s2) && return (nothing, nothing)
    return (uuid, s2)
end

"""
    get_or_create_named_session!(manager, name) -> NamedSession

Return the existing named session registered under the name alias `name`,
or atomically create and register one if absent. The check-and-create is
performed under a single `manager.lock` acquisition to prevent concurrent
callers from each creating a session and silently replacing the other's work.
"""
function get_or_create_named_session!(manager::SessionManager, name::AbstractString)
    lock(manager.lock) do
        key = String(name)
        # Check by name alias first.
        uuid = get(manager.name_to_uuid, key, nothing)
        if !isnothing(uuid)
            existing = get(manager.named_sessions, uuid, nothing)
            isnothing(existing) || return existing
        end
        session = NamedSession(string(uuid4()), key, Module(gensym(:REPLyNamedSession)))
        manager.named_sessions[session.id] = session
        if !isempty(key)
            manager.name_to_uuid[key] = session.id
        end
        return session
    end
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

Returns the name alias of each removed session, or its UUID if the session had no alias,
in the order they were swept.

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
    for (uuid, session_ref) in candidates
        destroyed = lock(manager.lock) do
            # Identity check: reject if a new session was created under the same UUID.
            get(manager.named_sessions, uuid, nothing) === session_ref || return false
            lock(session_ref.lock) do
                # State check: reject if the session became active since phase 2.
                session_ref.state === SessionIdle || return false
                session_ref.state = SessionClosed
            end
            delete!(manager.named_sessions, uuid)
            # Clean up alias mapping if it still points to this UUID.
            name = session_ref.name
            if !isempty(name) && get(manager.name_to_uuid, name, nothing) == uuid
                delete!(manager.name_to_uuid, name)
            end
            return true
        end
        # Report by name (alias) if present, otherwise by UUID.
        destroyed && push!(removed, isempty(session_ref.name) ? uuid : session_ref.name)
    end
    return removed
end

"""
    clone_named_session!(manager, source_id_or_name, dest_name)

Create a new named session with the alias `dest_name` by copying the module
bindings from the session identified by `source_id_or_name` (UUID or alias).
The clone gets its own UUID and anonymous module so mutations in the clone do
not affect the original.

Returns the new `NamedSession`, or `nothing` if `source_id_or_name` is not found.

Throws `ArgumentError` if `dest_name` alias already exists — callers must check
or close the existing session first.
"""
function clone_named_session!(manager::SessionManager, source_id_or_name::AbstractString, dest_name::AbstractString)
    # Hold the lock only for the structural dict operations. The binding copy
    # (deepcopy + Core.eval) runs outside the lock so it does not block other
    # tasks for the duration of potentially slow copies.
    source, dest = lock(manager.lock) do
        _, src = _resolve_to_uuid_and_session(manager, String(source_id_or_name))
        isnothing(src) && return (nothing, nothing)

        # dest_name is always an alias; check for alias collision.
        if haskey(manager.name_to_uuid, String(dest_name))
            throw(ArgumentError("session already exists: $(dest_name)"))
        end

        new_uuid = string(uuid4())
        dst = NamedSession(new_uuid, String(dest_name), Module(gensym(:REPLyNamedSession)))
        manager.named_sessions[new_uuid] = dst
        if !isempty(dest_name)
            manager.name_to_uuid[String(dest_name)] = new_uuid
        end
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
