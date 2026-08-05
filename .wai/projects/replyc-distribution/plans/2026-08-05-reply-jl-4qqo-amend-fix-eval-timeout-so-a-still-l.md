---
tags: [pipeline-run:ticket-workflow-2026-08-05-reply-jl-4qqo, pipeline-step:implement]
---

REPLy_jl-4qqo: Amend fix-eval-timeout so a still-live timed-out eval retains its EvalGate permit and active-task registration until actual termination; permanently quarantine named sessions; allow best-effort interrupt and bounded close but reject stdin/normal session operations promptly; retain hidden session/resource accounting through exactly-once completion cleanup; fail saturated zombie capacity promptly; specify race linearization, alias reuse safety, ephemeral ownership, and process isolation as the only hard reclamation boundary. Validate OpenSpec, review, then request explicit approval before REPLy_jl-kz6c implementation.
