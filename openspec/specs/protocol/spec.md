# Protocol Specification

_Version: 1.1 — 2026-04-17_

## Purpose

Define the wire format, message structure, status flags, encoding selection, and connection lifecycle for the Reply network REPL protocol — a flat JSON envelope inspired by nREPL. This is the canonical protocol-layer spec; operation-specific behavior is defined in `core-operations/spec.md`.

## Requirements

### Requirement: Flat JSON Envelope
All messages SHALL be JSON objects using a flat nREPL-shaped envelope with `op`, `id`, and optional `session` fields. Reply SHALL NOT use JSON-RPC 2.0 envelopes. (REQ-RPL-001)

#### Scenario: Valid request message
- **WHEN** a client sends `{"op":"eval","id":"msg-1","session":"<uuid>","code":"1+1"}`
- **THEN** the server parses all fields and routes to the eval handler

#### Scenario: Request without session
- **WHEN** a client sends `{"op":"clone","id":"msg-2"}` with no `session` field
- **THEN** the server treats it as a sessionless request; operation-specific behavior is defined by the relevant capability spec

### Requirement: Request ID Length Limit
The `id` field of every request SHALL be between 1 and `max_id_length` (default 256; see `resource-limits/spec.md`) characters. Requests with `id` longer than `max_id_length` SHALL be rejected with a protocol error. (REQ-RPL-001b)

#### Scenario: Oversized ID rejected
- **WHEN** a request arrives with `id` of 257 characters
- **THEN** the server returns `{"status":["done","error"],"err":"id exceeds maximum length"}`

#### Scenario: Valid ID at limit accepted
- **WHEN** a request arrives with `id` of exactly 256 characters
- **THEN** the server processes it normally

### Requirement: Response Correlation
Every response message SHALL include an `id` field copied verbatim from the corresponding request. (REQ-RPL-004)

#### Scenario: Streaming eval response carries request id
- **WHEN** the server evaluates `{"op":"eval","id":"req-1","code":"println(1)"}`
- **THEN** every response message (out chunks, value, done) carries `"id":"req-1"`

### Requirement: Stream Termination
Every request stream SHALL terminate with exactly one message containing `"done"` in its `status` array. No further messages with that `id` SHALL be emitted after the `done` message. (REQ-RPL-004)

#### Scenario: Done emitted once on success
- **WHEN** an eval completes successfully
- **THEN** exactly one response carries `"status":["done"]`

#### Scenario: No double done on parse error
- **WHEN** the eval code fails to parse
- **THEN** exactly one response carries `"status":["done","error"]` and no further messages are emitted for that `id`

### Requirement: Intra-Request Ordering
Within a single request `id`, response messages SHALL be emitted in causal order. For `eval`: stdout/stderr chunks precede the `value` message, which precedes the `done` message. (REQ-RPL-004b)

#### Scenario: Stdout before value before done
- **WHEN** `eval` produces stdout output before returning a value
- **THEN** all `out` chunks arrive before the `value` message, which arrives before `status:["done"]`

### Requirement: Streaming Responses
The server SHALL support streaming: a single request MAY produce one or more intermediate response messages before the terminating `status:["done"]` message. (REQ-RPL-005)

#### Scenario: Multiple stdout chunks before done
- **WHEN** code runs `for i in 1:3; println(i); end`
- **THEN** the server sends three separate `{"out":"...\n"}` messages before the final `done`

### Requirement: Unknown Field Tolerance
Unknown fields in request messages SHALL be ignored. Clients SHALL also ignore unknown fields in response messages. (REQ-RPL-006)

#### Scenario: Extra field in request ignored
- **WHEN** a client sends `{"op":"describe","id":"1","future-flag":true}`
- **THEN** the server ignores `future-flag` and responds normally

### Requirement: Kebab-Case Field Names
All wire-format JSON keys SHALL use `kebab-case` (e.g., `new-session`, `store-history`, `timeout-ms`). (REQ-RPL-007)

#### Scenario: Response uses kebab-case
- **WHEN** a `clone` response is emitted
- **THEN** the new session ID appears as `"new-session"` not `"new_session"`

### Requirement: Newline-Delimited JSON Wire Format
The default wire format SHALL be newline-delimited JSON: each message is a single JSON object encoded as UTF-8 terminated by `\n`. Messages SHALL NOT contain unescaped newlines. (REQ-RPL-008)

#### Scenario: Message framing with newline
- **WHEN** two messages are sent back to back
- **THEN** each is terminated by exactly one `\n` byte

### Requirement: Encoding Selection at Connection Establishment
The message encoding SHALL be selected at connection time, not inside a message. For v1.0, the only normative encoding is newline-delimited JSON. Future encodings MAY be added via URL scheme or per-listener configuration once separately specified. (REQ-RPL-009)

#### Scenario: Default encoding is JSON
- **WHEN** a client connects without specifying encoding
- **THEN** the server uses newline-delimited JSON

> **Note:** MessagePack framing (message delimitation without newlines) is deferred. When specified, it will use length-prefixed framing and become normative only once added to this spec.

### Requirement: Status Flags
Response `status` fields, when present, SHALL be JSON arrays of registered string flags. Unknown flags SHALL be ignored by clients. (REQ-RPL-004)

#### Scenario: Error response has done and error flags
- **WHEN** an eval raises a runtime exception
- **THEN** the response status contains both `"done"` and `"error"`

#### Scenario: Unknown status flag tolerated by client
- **WHEN** a client receives a response with an unrecognized status flag
- **THEN** the client ignores the unknown flag and processes known flags normally

### Requirement: Session ID Format
Server-generated session IDs SHALL be lowercase canonical UUIDv4 strings (36 characters including hyphens), generated using a cryptographically secure RNG (`Random.RandomDevice`). (REQ-RPL-003, REQ-RPL-003b)

#### Scenario: Session ID is UUIDv4
- **WHEN** a `clone` operation creates a new session
- **THEN** `new-session` matches the pattern `[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`

#### Scenario: Session IDs are unpredictable
- **WHEN** two sessions are created in the same process
- **THEN** their IDs are statistically independent (cannot be predicted from knowing one)

### Requirement: err Field Disambiguation
The `err` field appears in two contexts: stderr output chunks (no `status`) and error summary in error responses (`status` contains `"error"`). Clients SHALL use the presence of `"error"` in `status` to distinguish them. (REQ-RPL-005)

#### Scenario: Stderr chunk distinguished from error response
- **WHEN** an eval emits to stderr and then raises an exception
- **THEN** the stderr chunk carries `"err":"Warning...\n"` with no `status`, and the error response carries `"err":"ExceptionType:..."` with `"status":["done","error"]`
