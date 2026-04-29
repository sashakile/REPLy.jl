---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-1, pipeline-step:fix]
---

Fixes applied: (1) Documented replace-on-collision semantics in create_named_session! docstring, (2) Added caller-responsibility note for name validation, (3) Clarified session_count excludes named sessions, (4) Added duplicate-name replacement test, (5) Added sentinel binding isolation assertion in integration test. All 387 tests green.
