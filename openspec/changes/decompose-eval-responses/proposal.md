# Change: Decompose `eval_responses` — extract `run_with_timeout`, single `annotate_terminal!` (Step 9, B2)

## Why

`eval_responses` is a ~178-line god-function handling 8 concerns (parse, validate, slot acquire, eval, timeout, response rebuild, session management, error handling). Extract `run_with_timeout` + single `annotate_terminal!` pass to kill the 3× redundant response rebuilds (pure allocation win). Target: ~30-line coordinator.

**Depends on:** 
- Step 5 — `EvalGate` semaphore (B1), for clean slot acquire/release
- Step 8 — typed `EvalRequest` (B3), for clean input

## What Changes

- Extract `run_with_timeout(f, timeout)` from `eval_responses`
- Single `annotate_terminal!` pass replacing 3× redundant `map`+`merge` response rebuilds
- Wire up `EvalGate` and `EvalRequest` into the new coordinator
- Target: `eval_responses` becomes a ~30-line coordinator

## Impact

- Affected specs: `core-operations` (internal restructuring, no wire-visible change)
- Affected code: `src/eval.jl`
- Gate: improvement (post-release)
- Depends on: Step 5 `refactor-eval-concurrency`, Step 8 `add-typed-eval-request`