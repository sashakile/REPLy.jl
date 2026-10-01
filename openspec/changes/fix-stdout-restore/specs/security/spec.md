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

### Requirement: Global Stream Restoration on Shutdown
When the server shuts down, it SHALL restore `Base.stdout` and `Base.stderr` to their original values. (ARCH-008)

#### Scenario: Streams restored after close
- **WHEN** a server session completes and the server is closed
- **THEN** `Base.stdout` and `Base.stderr` are restored to their pre-server values

## Requirements

### Requirement: Global Stream Restoration on Shutdown
When the server shuts down, it SHALL restore `Base.stdout` and `Base.stderr` to their original values. (ARCH-008)

#### Scenario: Streams restored after close
- **WHEN** a server session completes and the server is closed
- **THEN** `Base.stdout` and `Base.stderr` are restored to their pre-server values
