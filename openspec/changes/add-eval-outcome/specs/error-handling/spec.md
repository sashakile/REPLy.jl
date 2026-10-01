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

### Requirement: EvalOutcome Discriminated Union
The eval subsystem SHALL represent eval termination as a discriminated union `EvalOutcome` with variants for `Completed`, `Interrupted`, `TimedOut`, `Errored`, and `Cancelled`. Serialization to the wire format (`status` array, `err`, `ex`) SHALL happen only at the edge. (ARCH-011)

#### Scenario: Completed outcome serialized correctly
- **WHEN** an eval completes successfully
- **THEN** `EvalOutcome.Completed` serializes to `{"status":["done"]}` with the result value

#### Scenario: Interrupted outcome has no error flag
- **WHEN** an eval is interrupted
- **THEN** `EvalOutcome.Interrupted` serializes to `{"status":["done","interrupted"]}` (no `"error"` flag)

### Requirement: Stable Error Codes for All Validation Paths
Every validation error in the eval pipeline SHALL include a stable, low-cardinality error code in the `status` array. Clients SHALL NOT be required to string-match the `err` field to categorize validation failures. (ARCH-013)

#### Scenario: Missing code field returns stable code
- **WHEN** an eval request is missing the `code` field
- **THEN** the response status includes `"missing-code"`

## Requirements

### Requirement: EvalOutcome Discriminated Union
The eval subsystem SHALL represent eval termination as a discriminated union `EvalOutcome` with variants for `Completed`, `Interrupted`, `TimedOut`, `Errored`, and `Cancelled`. Serialization to the wire format (`status` array, `err`, `ex`) SHALL happen only at the edge. (ARCH-011)

#### Scenario: Completed outcome serialized correctly
- **WHEN** an eval completes successfully
- **THEN** `EvalOutcome.Completed` serializes to `{"status":["done"]}` with the result value

#### Scenario: Interrupted outcome has no error flag
- **WHEN** an eval is interrupted
- **THEN** `EvalOutcome.Interrupted` serializes to `{"status":["done","interrupted"]}` (no `"error"` flag)

### Requirement: Stable Error Codes for All Validation Paths
Every validation error in the eval pipeline SHALL include a stable, low-cardinality error code in the `status` array. Clients SHALL NOT be required to string-match the `err` field to categorize validation failures. (ARCH-013)

#### Scenario: Missing code field returns stable code
- **WHEN** an eval request is missing the `code` field
- **THEN** the response status includes `"missing-code"`
