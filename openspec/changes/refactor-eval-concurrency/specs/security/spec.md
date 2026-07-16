## ADDED Requirements

### Requirement: EvalGate Semaphore
The eval concurrency limit SHALL be enforced by a single `EvalGate` semaphore type whose `release!` atomically decrements the active count and notifies waiters. The `eval` module SHALL NOT directly manipulate `active_evals`. (ARCH-009)

#### Scenario: EvalGate blocks at max concurrent
- **WHEN** `max_concurrent_evals` evals are in flight and a new eval arrives
- **THEN** `EvalGate.acquire!` blocks until an active eval completes