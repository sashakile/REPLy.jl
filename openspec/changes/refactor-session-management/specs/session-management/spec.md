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

### Requirement: Lock Ownership Documentation
Every field of `NamedSession` SHALL document which lock protects it (or note that it is immutable/atomic and needs no lock). Mutators for lock-guarded fields SHALL include a runtime assertion that the relevant lock is held. (ARCH-014)

#### Scenario: Mutator asserts lock is held
- **WHEN** a field of `NamedSession` is mutated
- **THEN** an `@assert islocked(lock)` check fires if the protecting lock is not held

## Requirements

### Requirement: Lock Ownership Documentation
Every field of `NamedSession` SHALL document which lock protects it (or note that it is immutable/atomic and needs no lock). Mutators for lock-guarded fields SHALL include a runtime assertion that the relevant lock is held. (ARCH-014)

#### Scenario: Mutator asserts lock is held
- **WHEN** a field of `NamedSession` is mutated
- **THEN** an `@assert islocked(lock)` check fires if the protecting lock is not held
