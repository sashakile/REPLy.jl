---
tags: [pipeline-run:ticket-workflow-2026-08-05-reply-jl-kz6c, pipeline-step:fix]
---

Fixes applied: implemented lifecycle-owned eval admission and cleanup; retained gate, active-task, and session/resource accounting until actual task termination; quarantined named zombies and retained ephemeral zombies; made close/shutdown bounded and liveness-aware; unified eval/load-file FIFO admission; made cancellation exactly once and race-safe across timeout, interrupt, close, and shutdown; fixed queued typed responses, pre-gate detached cleanup, timeout-setup cancellation ownership, and atomic queued-to-running admission. Verification: focused lifecycle suite 1107/1107; final blocker review clean; OpenSpec strict valid; git diff check clean. Full suite 3686/3689 with only pre-existing environment-dependent build_test.jl:36-38 scratch-directory failures. ah check reports known tool limitations: 40 overlay conflicts for modified scenarios and 156 pre-existing no-tests-declared findings.
