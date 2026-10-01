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

### Requirement: Thread-Safe Audit Log Read Access
The audit log SHALL provide a thread-safe read accessor that locks `log.lock` before copying `log.entries`. (ARCH-003)

#### Scenario: Concurrent read during write does not race
- **WHEN** `audit_entries` is called while `record_audit!` is writing
- **THEN** the read returns a consistent snapshot (no `BoundsError` or torn entries)

## Requirements

### Requirement: Thread-Safe Audit Log Read Access
The audit log SHALL provide a thread-safe read accessor that locks `log.lock` before copying `log.entries`. (ARCH-003)

#### Scenario: Concurrent read during write does not race
- **WHEN** `audit_entries` is called while `record_audit!` is writing
- **THEN** the read returns a consistent snapshot (no `BoundsError` or torn entries)
