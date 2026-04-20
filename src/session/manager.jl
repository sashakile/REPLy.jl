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
    ephemeral_sessions::Vector{ModuleSession}
    named_sessions::Dict{String,NamedSession}
end

SessionManager() = SessionManager(ModuleSession[], Dict{String,NamedSession}())

"""
    create_ephemeral_session!(manager)

Create and register a new ephemeral session backed by an anonymous module.
"""
function create_ephemeral_session!(manager::SessionManager)
    session = ModuleSession(Module(gensym(:REPLySession)))
    push!(manager.ephemeral_sessions, session)
    return session
end

"""
    destroy_session!(manager, session)

Remove `session` from `manager`. This operation is idempotent so cleanup code
can call it safely from both success and error paths.
"""
function destroy_session!(manager::SessionManager, session::ModuleSession)
    filter!(existing -> existing !== session, manager.ephemeral_sessions)
    return nothing
end

"""
    session_count(manager)

Return the number of registered ephemeral sessions. Named sessions are not
counted here; use `length(list_named_sessions(manager))` for those.
"""
session_count(manager::SessionManager) = length(manager.ephemeral_sessions)

"""
    create_named_session!(manager, name)

Create and register a persistent named session. The session is keyed by
`name` and will appear in `list_named_sessions` output.

If a session with `name` already exists it is silently replaced — the old
module and its bindings become unreachable via the registry.

Name validation (e.g. rejecting empty strings) is the caller's responsibility.
"""
function create_named_session!(manager::SessionManager, name::AbstractString)
    session = NamedSession(String(name), Module(gensym(:REPLyNamedSession)), time())
    manager.named_sessions[session.name] = session
    return session
end

"""
    list_named_sessions(manager)

Return all registered persistent named sessions. Ephemeral sessions are
never included — this is the authoritative source for `ls-sessions`.
"""
list_named_sessions(manager::SessionManager) = collect(values(manager.named_sessions))

"""
    lookup_named_session(manager, name)

Return the `NamedSession` registered under `name`, or `nothing` if no such
session exists.
"""
function lookup_named_session(manager::SessionManager, name::AbstractString)
    get(manager.named_sessions, String(name), nothing)
end

"""
    destroy_named_session!(manager, name)

Remove the named session registered under `name`. This operation is
idempotent — calling it when no such session exists is safe.
"""
function destroy_named_session!(manager::SessionManager, name::AbstractString)
    delete!(manager.named_sessions, String(name))
    return nothing
end
