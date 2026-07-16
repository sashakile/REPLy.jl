# Change: Refactor eval concurrency — EvalGate semaphore + bounded wait (B1, A2)

## Why

The eval-slot invariant (`active_evals` increment/decrement) is split across two files: `_eval_acquire_slot` (`server_state.jl:65`) increments; `_eval_release_slot` (`:97`) does **not** decrement (its docstring says the caller must decrement first); the actual decrement lives in `eval.jl:465`. Check-then-act spans an atomic **and** a condition var → fuzzy cap under contention. This is a precondition for A2's bounded-wait fix and for decomposing `eval_responses` (B2).

## What Changes

- Extract a single `EvalGate` type (semaphore) whose `release!` owns both decrement + condition-var notify
- `eval.jl` never touches `active_evals` directly
- This is the structural precondition for the bounded-wait fix (separate change: `fix-eval-timeout`)

## Impact

- Affected specs: `security` (resource limit enforcement scenarios)
- Affected code: `src/server_state.jl`, `src/eval.jl`
- Depends on: nothing (structural only, no behavior change)
- Enables: `fix-eval-timeout`, `refactor-eval-pipeline`