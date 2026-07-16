# Change: Bounded wait for non-interruptible eval — release slot on timeout (R5 ⚖️, A2)

## Why

A non-interruptible eval (tight `ccall`, BLAS, native code) never observes `InterruptException` → `fetch(eval_task)` in `eval.jl:461-467` blocks forever, the eval slot is never released, and after `max_concurrent_evals` (10) such evals the server silently freezes eval intake — while `max-eval-time-ms` is advertised as a hard bound.

**Product decision needed:** Ship the bounded-wait mitigation, OR explicitly document "timeout is best-effort; hard bound is process isolation" as a known limitation. Silence is the only non-option.

## What Changes

- Decouple bounded wait from task completion in `eval.jl`
- Release eval slot on timeout even if task is still running
- Track zombie evals that escape the timeout
- Document the true hard bound (process isolation via Malt.jl heavy sessions)
- (If the mitigation is chosen) Add a `timedwait`-style bounded fetch

## Impact

- Affected specs: `security` (Resource Limit Enforcement scenarios)
- Affected code: `src/eval.jl`, `src/server_state.jl`
- Release blocker: R5 (decision needed before classification)
