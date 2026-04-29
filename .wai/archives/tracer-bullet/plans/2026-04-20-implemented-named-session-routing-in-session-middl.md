---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-2, pipeline-step:implement]
---

Implemented named-session routing in session middleware: requests with session_id resolve named sessions via lookup_named_session, sessionless requests use ephemeral, missing sessions return session-not-found error. Updated RequestContext.session type to Union{ModuleSession, NamedSession, Nothing}. Added session_not_found_response helper. Refactored eval_responses ephemeral tracking to satisfy JET static analysis.
