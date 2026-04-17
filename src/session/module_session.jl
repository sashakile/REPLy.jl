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
