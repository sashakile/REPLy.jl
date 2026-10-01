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

### Requirement: Chunked Message Read
The message reading implementation SHALL use chunked reads (not byte-at-a-time) with a reusable per-connection buffer. (ARCH-020)

#### Scenario: Chunked read produces same result
- **WHEN** a message of any size is received
- **THEN** the chunked read produces the same message content as a byte-at-a-time read

## Requirements

### Requirement: Chunked Message Read
The message reading implementation SHALL use chunked reads (not byte-at-a-time) with a reusable per-connection buffer. (ARCH-020)

#### Scenario: Chunked read produces same result
- **WHEN** a message of any size is received
- **THEN** the chunked read produces the same message content as a byte-at-a-time read
