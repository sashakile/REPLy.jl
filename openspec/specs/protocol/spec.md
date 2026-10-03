---
id: spec
kind: intent
statement: "WHEN a client exchanges messages with the Reply server over the wire, THE server SHALL parse flat JSON envelopes, correlate every response to its request id, terminate each request stream with exactly one done, emit messages in causal order, and frame them as newline-delimited JSON."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| FLAT_ENVELOPE | invariant | every wire message is a flat JSON object carrying `op`, `id`, and optionally `session`; JSON-RPC 2.0 envelopes are never emitted or required | [[spec]] |
| ID_CORRELATION | invariant | every response message echoes the request's `id` verbatim, and each request stream ends with exactly one `status` containing `done` with no further messages for that `id` after it | [[spec]] |
| CAUSAL_ORDER | invariant | within one request id, stdout/stderr chunks precede the `value` message, which precedes the terminating `done` message | [[spec]] |
| NLJSON_FRAMING | invariant | the default wire encoding is newline-delimited UTF-8 JSON selected at connection time; each frame is one JSON object terminated by exactly one `\n` | [[spec]] |

## Model

### States

- `connected`
- `request_parsed`
- `streaming`
- `done`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| parse_request | connected | request_parsed | [[spec.FLAT_ENVELOPE]] |
| emit_stream | request_parsed | streaming | [[spec.CAUSAL_ORDER]] |
| terminate | streaming | done | [[spec.ID_CORRELATION]] |
| new_request | done | connected | [[spec.NLJSON_FRAMING]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| envelope_requests_route | unit | [[spec.FLAT_ENVELOPE]] | `test/unit/protocol_spec_test.jl` | a fully-formed eval request parses and routes to the eval handler; a sessionless request is accepted and handled by the relevant operation |
| id_length_enforced | unit | [[spec.FLAT_ENVELOPE]] | `test/unit/protocol_spec_test.jl` | an id over `max_id_length` is rejected with `id exceeds maximum length of <max_id_length>` while an id at the limit processes normally |
| responses_correlate_and_terminate | unit | [[spec.ID_CORRELATION]] | `test/unit/protocol_spec_test.jl` | every streamed response echoes the request id; success emits exactly one done; a parse error emits exactly one done+error with no further messages for that id |
| stream_ordering_holds | unit | [[spec.CAUSAL_ORDER]] | `test/unit/protocol_spec_test.jl` | three separate out chunks arrive before done; out precedes value precedes done |
| framing_is_nljson | unit | [[spec.NLJSON_FRAMING]] | `test/unit/protocol_spec_test.jl` | each message is terminated by exactly one `\n`; a bare tcp connection negotiates nothing and speaks newline-delimited JSON by default |
| status_flags_and_fields | unit | [[spec.ID_CORRELATION]] | `test/unit/protocol_spec_test.jl` | error responses carry both `done` and `error`; unknown request fields are ignored; wire keys are kebab-case (`new-session`); unknown status flags do not disturb known-flag processing; stderr chunks (`err` without status) are distinguishable from error responses (`err` with status) |

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
- **THEN** the server returns `{"status":["done","error"],"err":"id exceeds maximum length of <max_id_length>"}`

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
