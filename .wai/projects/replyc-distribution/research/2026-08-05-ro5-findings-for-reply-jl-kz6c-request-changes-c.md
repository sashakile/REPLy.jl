---
tags: [pipeline-run:ticket-workflow-2026-08-05-reply-jl-kz6c, pipeline-step:review]
---

Ro5 findings for REPLy_jl-kz6c: REQUEST CHANGES. Critical: timeout classification and completion are not atomic; close detaches ordinary live evals but only zombie cleanup finalizes them; same-session queued eval timeout/close can act on the wrong running task. High: repeated interrupts are not request-once; admission/deferred cleanup are not exception-safe; shutdown can miss admission; clone source routing bypasses quarantine. Tests manually fabricate lifecycle states and miss real-handler races. Required fix: one per-eval lifecycle/lease record owning atomic state, cancellation, permit/registry/session identity and exactly-once cleanup; completion observer for every admitted eval; cancellable per-session queued records or equivalent; centralized lifecycle-aware lookup; production-path race and fault tests.
