---
id: spec
kind: intent
statement: "WHEN the migrated delta is elaborated, THE author SHALL replace this scaffold statement with the real requirement."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| scaffold_constraint | invariant | `true` | [[spec]] |

## Model

### States

- `draft`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| scaffold_transition | draft | draft | [[spec.scaffold_constraint]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| scaffold_property | unit | [[spec.scaffold_constraint]] | `todo()` | `true` |

## ADDED Requirements

### Requirement: EvalGate Semaphore
The eval concurrency limit SHALL be enforced by a single `EvalGate` semaphore type whose `release!` atomically decrements the active count and notifies waiters. The `eval` module SHALL NOT directly manipulate `active_evals`. (ARCH-009)

#### Scenario: EvalGate blocks at max concurrent
- **WHEN** `max_concurrent_evals` evals are in flight and a new eval arrives
- **THEN** `EvalGate.acquire!` blocks until an active eval completes

## Requirements

### Requirement: EvalGate Semaphore
The eval concurrency limit SHALL be enforced by a single `EvalGate` semaphore type whose `release!` atomically decrements the active count and notifies waiters. The `eval` module SHALL NOT directly manipulate `active_evals`. (ARCH-009)

#### Scenario: EvalGate blocks at max concurrent
- **WHEN** `max_concurrent_evals` evals are in flight and a new eval arrives
- **THEN** `EvalGate.acquire!` blocks until an active eval completes
