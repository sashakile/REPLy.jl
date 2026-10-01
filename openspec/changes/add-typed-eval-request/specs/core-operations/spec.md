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

### Requirement: EvalRequest Parsed at Handler Boundary
The eval handler SHALL parse the raw request dict into a typed `EvalRequest` struct at the handler boundary. All semantic fields SHALL be validated once during parsing. Downstream code SHALL read from the typed struct, not re-fetch from the raw dict. (ARCH-010)

#### Scenario: Invalid EvalRequest rejected at boundary
- **WHEN** an eval request arrives with a missing `code` field
- **THEN** the parse step returns an error response before any handler logic runs

## Requirements

### Requirement: EvalRequest Parsed at Handler Boundary
The eval handler SHALL parse the raw request dict into a typed `EvalRequest` struct at the handler boundary. All semantic fields SHALL be validated once during parsing. Downstream code SHALL read from the typed struct, not re-fetch from the raw dict. (ARCH-010)

#### Scenario: Invalid EvalRequest rejected at boundary
- **WHEN** an eval request arrives with a missing `code` field
- **THEN** the parse step returns an error response before any handler logic runs
