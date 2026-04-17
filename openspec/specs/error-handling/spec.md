# Error Handling

_Version: 1.1 — 2026-04-17_

## Purpose

Specify the error response format, error categories, safe exception serialization, and the disconnection policy for repeated malformed messages. The one-done-per-request invariant is defined canonically in the protocol spec (see `protocol/spec.md`, REQ-RPL-004).

## Requirements

### Requirement: Error Response Format
All error responses SHALL include: `id`, `status` containing `"done"` and `"error"`, `err` (human-readable summary), and optionally `ex` (structured exception with `type` and `message`), `stacktrace` (array of frame records), and `cause` (nested error or null). (REQ-RPL-063)

#### Scenario: Eval runtime error response shape
- **WHEN** code raises `UndefVarError: y not defined`
- **THEN** response has `"err":"UndefVarError: y not defined"`, `"ex":{"type":"UndefVarError","message":"y not defined"}`, `"stacktrace":[...]`, `"status":["done","error"]`

#### Scenario: Parse error response shape
- **WHEN** code contains a syntax error
- **THEN** response has `"ex":{"type":"Base.Meta.ParseError",...}` and `"status":["done","error"]`

### Requirement: Safe Exception Message Extraction
`ex.message` SHALL be extracted without assuming the exception has a `.msg` field. The safe pattern uses `hasfield(typeof(ex), :msg)` with fallback to `sprint(showerror, ex)`. (REQ-RPL-061)

#### Scenario: Exception without .msg field
- **WHEN** a custom exception type without a `.msg` field is raised
- **THEN** `ex.message` is populated via `sprint(showerror, ex)` rather than raising a `FieldError`

### Requirement: Error Status Flags
The server SHALL use distinct status flags for each error category so clients can programmatically distinguish failure modes. (REQ-RPL-063)

#### Scenario: Session not found
- **WHEN** a request references a non-existent session
- **THEN** response has `"status":["done","error","session-not-found"]`

#### Scenario: Eval timeout
- **WHEN** eval exceeds the time limit
- **THEN** response has `"status":["done","error","timeout"]` and `"err":"Eval timed out after N ms"`

#### Scenario: Rate limit exceeded
- **WHEN** a client exceeds `rate_limit_per_min`
- **THEN** response has `"status":["done","error"]` and `"err":"Rate limit exceeded"`

#### Scenario: Unknown operation
- **WHEN** no middleware handles the op
- **THEN** response has `"status":["done","unknown-op"]`

### Requirement: Interrupted Termination
Eval interruption is a distinct, non-error termination mode. The `status` array contains `"done"` and `"interrupted"` but NOT `"error"`. Clients SHALL use the absence of `"error"` in `status` to distinguish interrupts from errors. (REQ-RPL-014)

> **Note:** The MCP adapter maps `interrupted` to `isError = true` because MCP's `CallToolResult` has no concept of non-error termination — this is a deliberate adapter-layer decision, not a protocol-level classification. See `mcp-adapter/spec.md`.

#### Scenario: Eval interrupted has no error flag
- **WHEN** eval is cancelled by an interrupt op
- **THEN** response has `"status":["done","interrupted"]` (no `"error"` flag)

### Requirement: Repeated Malformed Messages Cause Disconnection
After 10 consecutive malformed messages from a single connection, the server SHALL close that connection. Individual malformed message handling is defined in `core-operations/spec.md` (REQ-RPL-020). (REQ-RPL-020)

#### Scenario: Consecutive malformed messages disconnect client
- **WHEN** a client sends 10 consecutive messages with no valid `id` or `op`
- **THEN** the server closes the connection
