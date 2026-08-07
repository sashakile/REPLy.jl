---
tags: [pipeline-run:ticket-workflow-2026-08-05-reply-jl-kz6c, pipeline-step:fix]
---

Final review blockers for REPLy_jl-kz6c: detached cleanup must wait for both running_lifecycle empty and eval_queue empty; load-file must share lifecycle admission/completion with eval; wake_lifecycle check-then-put can deadlock; timeout setup must be exception-safe and always request cancellation with coherent partial-accounting ownership. Add production-path regressions before closure.
