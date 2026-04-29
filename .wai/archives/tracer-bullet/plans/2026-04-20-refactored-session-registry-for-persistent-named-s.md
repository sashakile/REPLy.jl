---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-1, pipeline-step:implement]
---

Refactored session registry for persistent named session identity.

Changes:
- module_session.jl: Added NamedSession struct with name, session_mod, created_at fields. Added session_name/session_module/session_created_at accessors.
- manager.jl: Replaced sessions::Vector{ModuleSession} with ephemeral_sessions + named_sessions::Dict{String,NamedSession}. Added create_named_session!, list_named_sessions, lookup_named_session, destroy_named_session!. Existing ephemeral API unchanged.
- Tests: session_registry_test.jl (9 unit tests) and session_lifecycle_test.jl (3 integration tests) covering create/list/lookup/destroy and the key invariant that ephemeral sessions never appear in list_named_sessions.

All 382 tests pass.
