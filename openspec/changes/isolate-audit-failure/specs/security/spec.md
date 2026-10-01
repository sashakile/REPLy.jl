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

### Requirement: Audit Write Failure Degradation
Audit-log write failures SHALL NOT propagate to the request path. If `record_audit!` fails (e.g., disk full), the server SHALL log a warning and continue; the eval result is returned to the client as if the audit succeeded. (ARCH-004)

#### Scenario: Disk-full audit does not abort successful eval
- **WHEN** an eval completes successfully but the audit log write fails
- **THEN** the client receives the eval result, not an internal error

## Requirements

### Requirement: Audit Write Failure Degradation
Audit-log write failures SHALL NOT propagate to the request path. If `record_audit!` fails (e.g., disk full), the server SHALL log a warning and continue; the eval result is returned to the client as if the audit succeeded. (ARCH-004)

#### Scenario: Disk-full audit does not abort successful eval
- **WHEN** an eval completes successfully but the audit log write fails
- **THEN** the client receives the eval result, not an internal error
