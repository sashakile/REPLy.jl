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

### Requirement: Single Response Annotation Pass
The eval response builder SHALL annotate the terminal response (status, err, ex fields) in a single pass, not multiple redundant rebuilds. (ARCH-021)

#### Scenario: Single pass produces same response
- **WHEN** an eval completes
- **THEN** the response shape is identical to the previous multi-pass approach

## Requirements

### Requirement: Single Response Annotation Pass
The eval response builder SHALL annotate the terminal response (status, err, ex fields) in a single pass, not multiple redundant rebuilds. (ARCH-021)

#### Scenario: Single pass produces same response
- **WHEN** an eval completes
- **THEN** the response shape is identical to the previous multi-pass approach
