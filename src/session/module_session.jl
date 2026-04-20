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
    NamedSession

Persistent named session with explicit identity and metadata.
Tracked separately from ephemeral sessions so it can appear in `ls-sessions`
output while ephemeral sessions never do.
"""
struct NamedSession
    name::String
    session_mod::Module
    created_at::Float64
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
