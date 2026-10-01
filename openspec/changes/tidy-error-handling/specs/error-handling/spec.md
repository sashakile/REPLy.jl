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

### Requirement: Malformed JSON Returns Error Response
When a message cannot be parsed as valid JSON, the server SHALL return `{"status":["done","error","malformed-request"],"err":"Malformed JSON"}` and increment the consecutive-malformed counter. The connection SHALL NOT be closed until the 10-malformed threshold. (ARCH-018)

#### Scenario: Malformed JSON gets error response
- **WHEN** a client sends invalid JSON
- **THEN** the server responds with `"malformed-request"` status and keeps the connection open

### Requirement: File-Read Error Classification
File-read errors in `load-file` SHALL be classified into stable error codes: `path-not-allowed`, `file-not-found`, and `io-error`. Raw error messages SHALL NOT leak server file paths. (ARCH-019)

#### Scenario: Non-existent file returns file-not-found
- **WHEN** a `load-file` request references a non-existent path
- **THEN** the response status includes `"file-not-found"` without leaking the absolute path

## Requirements

### Requirement: Malformed JSON Returns Error Response
When a message cannot be parsed as valid JSON, the server SHALL return `{"status":["done","error","malformed-request"],"err":"Malformed JSON"}` and increment the consecutive-malformed counter. The connection SHALL NOT be closed until the 10-malformed threshold. (ARCH-018)

#### Scenario: Malformed JSON gets error response
- **WHEN** a client sends invalid JSON
- **THEN** the server responds with `"malformed-request"` status and keeps the connection open

### Requirement: File-Read Error Classification
File-read errors in `load-file` SHALL be classified into stable error codes: `path-not-allowed`, `file-not-found`, and `io-error`. Raw error messages SHALL NOT leak server file paths. (ARCH-019)

#### Scenario: Non-existent file returns file-not-found
- **WHEN** a `load-file` request references a non-existent path
- **THEN** the response status includes `"file-not-found"` without leaking the absolute path
