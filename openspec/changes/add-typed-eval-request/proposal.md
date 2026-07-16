# Change: Parse-don't-validate typed EvalRequest at handler boundary (Step 8, B3)

## Why

`validate_request` checks only the envelope; semantic fields are re-fetched and re-validated in ≥3 handlers (`eval.jl:293,299,302`). Parsing once at the boundary into a typed `EvalRequest` struct eliminates redundant work and provides a single point of validation. This is the vehicle for decomposing `eval_responses` (Step 9) and for retiring the `isnothing(server_state)` guards from B7.

**Depends on:** Step 3 — `ResourceLimits` value object (B7), because typed `EvalRequest` needs access to `ResourceLimits` for field validation (e.g., `max_id_length`).

## What Changes

- Define typed `EvalRequest` struct with validated fields
- Implement `parse_eval_request(dict::Dict) -> Union{EvalRequest, ErrorResponse}` at the handler boundary
- Remove redundant field re-fetching from downstream handlers

## Impact

- Affected specs: `core-operations` (eval request shape)
- Affected code: `src/eval.jl`, `src/core_operations.jl`
- Gate: improvement (post-release)
- Depends on: Step 3 `refactor-resource-limits`
