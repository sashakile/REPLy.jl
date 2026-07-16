# Change: Add `EvalOutcome` discriminated union + stable error codes (Step 10, B4)

## Why

Stringly-typed `status` arrays + symbol-tagged tuples = ad-hoc state machines. Many validation errors carry no stable machine code (verified at `eval.jl:293-302`), forcing clients to string-match prose. An internal `EvalOutcome` discriminated union serialized to the frozen wire form only at the edge makes the eval state machine explicit and adds stable low-cardinality codes to every validation error.

**Depends on:** Step 9 — decomposed `eval_responses` (B2).

## What Changes

- Define internal `EvalOutcome` discriminated union: `Completed`, `Interrupted`, `TimedOut`, `Errored`, `Cancelled`
- Serialize to wire format (status array + err + ex) only at the edge
- Add stable low-cardinality error codes to every validation error

## Impact

- Affected specs: `error-handling` (stable error codes)
- Affected code: `src/eval.jl`, `src/core_operations.jl`
- Gate: improvement (post-release)
- Depends on: Step 9 `decompose-eval-responses`
