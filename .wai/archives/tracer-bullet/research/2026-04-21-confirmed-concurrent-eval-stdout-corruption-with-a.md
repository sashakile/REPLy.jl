---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

Confirmed concurrent eval stdout corruption with a deterministic yield()-based unit test. IOCapture v1.0.0 is not viable here: it merges stdout/stderr and nested concurrent captures error with dup bad file descriptor on Julia 1.12. Fixed immediate corruption by serializing eval stdio capture behind a ReentrantLock while preserving existing stdout/stderr message semantics.
