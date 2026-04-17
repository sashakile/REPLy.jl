"""
    SessionManager

Track ephemeral `ModuleSession`s for tracer-bullet eval requests.
`session_count` is used to detect leaks in tests and integration flows.
"""
mutable struct SessionManager
    sessions::Vector{ModuleSession}
end

SessionManager() = SessionManager(ModuleSession[])

"""
    create_ephemeral_session!(manager)

Create and register a new ephemeral session backed by an anonymous module.
"""
function create_ephemeral_session!(manager::SessionManager)
    session = ModuleSession(Module(gensym(:REPLySession)))
    push!(manager.sessions, session)
    return session
end

"""
    destroy_session!(manager, session)

Remove `session` from `manager`. This operation is idempotent so cleanup code
can call it safely from both success and error paths.
"""
function destroy_session!(manager::SessionManager, session::ModuleSession)
    filter!(existing -> existing !== session, manager.sessions)
    return nothing
end

"""
    session_count(manager)

Return the number of registered ephemeral sessions.
"""
session_count(manager::SessionManager) = length(manager.sessions)
