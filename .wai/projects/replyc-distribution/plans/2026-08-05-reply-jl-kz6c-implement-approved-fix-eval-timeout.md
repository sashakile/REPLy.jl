---
tags: [pipeline-run:ticket-workflow-2026-08-05-reply-jl-kz6c, pipeline-step:implement]
---

REPLy_jl-kz6c: Implement approved fix-eval-timeout via deterministic TDD. First encode timeout/task-completion, retained permit/accounting, quarantine/rejection, bounded liveness-aware close, ephemeral zombie, and gate-saturation races. Then centralize exactly-once completion ownership and add the smallest session/gate lifecycle state needed. Verify focused races, full suite, strict OpenSpec, and ah correspondence; perform Ro5 review/fix before commit.
