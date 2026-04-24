# Core Operations

_Version: 1.1 — 2026-04-17_

## Purpose

Specify all built-in Reply protocol operations: `describe`, `eval`, `load-file`, `interrupt`, `complete`, `lookup`, `stdin`, `close`, `clone`, `ls-sessions`, and fallback handling for unknown or malformed operations. The `close`, `clone`, and `ls-sessions` operations are handled by `SessionMiddleware`; see `middleware/spec.md` for stack assignment.

## Requirements

### Requirement: describe Operation
The server SHALL implement the `describe` operation returning supported ops, middleware, server version, and available/current encodings. (REQ-RPL-010)

The response SHALL include:
- `ops`: Dict mapping operation name to an operation descriptor with `doc` (string), `requires` (array of required field names), `optional` (array of optional field names), and `returns` (array of response field names).
- `versions`: Dict with `julia` (Julia VERSION string) and `reply` (Reply protocol version string).
- `encodings-available`: Array of encoding names the server currently supports on this server instance (for v1.0, at least `["json"]`).
- `encoding-current`: String naming the encoding used on this connection.
- `status`: `["done"]`

#### Scenario: Describe response shape
- **WHEN** a client sends `{"op":"describe","id":"1"}`
- **THEN** the response includes `ops` (with at least `eval`, `clone`, `close`, `complete`, `lookup`, `interrupt`, `ls-sessions`, `stdin`, `load-file`), `versions` (with `julia` and `reply` keys), `encodings-available`, `encoding-current`, and `status:["done"]`

### Requirement: eval Operation
The server SHALL implement the `eval` operation to evaluate Julia code in a session. When eval produces stdout or stderr output, the server SHALL emit the corresponding `out`/`err` response chunks before the terminal `value` and `done` messages, with no intentional buffering beyond transport/runtime chunking. (REQ-RPL-011)

#### Scenario: Successful eval
- **WHEN** a client sends `{"op":"eval","id":"2","session":"<id>","code":"1+1"}`
- **THEN** the server returns `{"value":"2","ns":"Main"}` followed by `{"status":["done"]}`

#### Scenario: Eval with stdout
- **WHEN** code calls `println("hello")`
- **THEN** the server emits `{"out":"hello\n"}` before the `value` message

#### Scenario: Empty code returns nothing
- **WHEN** code is the empty string `""`
- **THEN** the server returns `{"value":"nothing","ns":"Main"}` then `{"status":["done"]}` (REQ-RPL-011b)

#### Scenario: Dotted module path resolved
- **WHEN** `module` is `"Main.Foo.Bar"` and that module exists
- **THEN** eval runs in `Main.Foo.Bar` (REQ-RPL-011c)

#### Scenario: Unresolvable module returns error
- **WHEN** `module` is `"Main.DoesNotExist"`
- **THEN** the server returns `{"status":["done","error"],"err":"Cannot resolve module: ..."}` (REQ-RPL-011c)

#### Scenario: allow-stdin false causes EOFError
- **WHEN** `allow-stdin` is `false` and code calls `readline()`
- **THEN** the call raises `EOFError` immediately (REQ-RPL-011d)

#### Scenario: timeout-ms below 1 rejected
- **WHEN** `timeout-ms` is `0`
- **THEN** server returns `{"status":["done","error"],"err":"timeout-ms must be ≥ 1"}` (REQ-RPL-011e)

#### Scenario: timeout-ms capped at max
- **WHEN** `timeout-ms` exceeds `ResourceLimits.max_eval_time_ms`
- **THEN** the effective timeout is silently capped to `max_eval_time_ms` (REQ-RPL-011e)

#### Scenario: silent suppresses value
- **WHEN** `silent` is `true`
- **THEN** no `value` field is emitted; `out`, `err`, and error responses are still sent

#### Scenario: store-history false skips ans
- **WHEN** `store-history` is `false`
- **THEN** `ans` and the session `history` vector are not updated, even on success

### Requirement: eval Value Truncation
The `value` field is `repr(result)`. If it exceeds `ResourceLimits.max_value_repr_bytes` (default 1 MB), the value SHALL be truncated with suffix `"\n…[truncated to N bytes]"` and `done` SHALL include `truncated:true`. (REQ-RPL-047i)

#### Scenario: Large repr truncated with flag
- **WHEN** `repr(result)` exceeds `max_value_repr_bytes`
- **THEN** `value` is truncated and `done` contains `"truncated":true`

### Requirement: load-file Operation
The server SHALL implement `load-file`, equivalent to reading a file and evaluating it as `eval` with file/line propagated. (REQ-RPL-013)

#### Scenario: File loaded and evaluated
- **WHEN** a client sends `{"op":"load-file","id":"3","file":"/path/to/script.jl"}`
- **THEN** the file is executed with stack traces referencing the file path

#### Scenario: Path allowlist enforced
- **WHEN** the server has a `load_file_allowlist` and the path is outside it
- **THEN** returns `{"status":["done","error","path-not-allowed"],"err":"Path not allowed: ..."}` without leaking file contents (REQ-RPL-013b)

#### Scenario: Unreadable file returns error
- **WHEN** the file does not exist or cannot be read
- **THEN** returns `{"status":["done","error"],"err":"Failed to read file: ..."}`

### Requirement: interrupt Operation
The server SHALL implement `interrupt` to stop in-flight evaluation in a session. (REQ-RPL-014)

#### Scenario: Interrupt running eval
- **WHEN** `interrupt` targets a running eval by `interrupt-id`
- **THEN** the interrupted eval stream terminates with `{"status":["done","interrupted"]}`

#### Scenario: Interrupt completed eval is idempotent
- **WHEN** `interrupt-id` references an eval that has already completed
- **THEN** the interrupt response has `"interrupted":[]` and `"status":["done"]`

#### Scenario: Interrupt without interrupt-id cancels all
- **WHEN** `interrupt-id` is omitted
- **THEN** all in-flight evals in the session are interrupted

### Requirement: complete Operation
The server SHALL implement `complete` to return code completions at a cursor position. (REQ-RPL-015)

#### Scenario: Completion results returned
- **WHEN** a client sends `{"op":"complete","id":"4","code":"pri","pos":3}`
- **THEN** response includes a `completions` array with matching names and `type` fields

#### Scenario: Out-of-bounds pos returns empty completions
- **WHEN** `pos` is negative or exceeds `length(code)` bytes
- **THEN** the server returns `completions:[]` with `status:["done"]`, not an error (REQ-RPL-015b)

### Requirement: lookup Operation
The server SHALL implement `lookup` to return symbol documentation and method information. (REQ-RPL-016)

#### Scenario: Symbol found
- **WHEN** `{"op":"lookup","symbol":"println","module":"Base"}` is sent
- **THEN** response has `"found":true` with `name`, `type`, `doc`, `methods`, and `status:["done"]`

#### Scenario: Symbol not found
- **WHEN** the symbol does not exist in the specified module
- **THEN** response has `"found":false` and `status:["done"]`

### Requirement: stdin Operation
The server SHALL implement `stdin` to provide input to an eval blocked on `readline()`. (REQ-RPL-017)

#### Scenario: Input unblocks waiting eval
- **WHEN** an eval is waiting on `readline()` and the server has emitted a response with `status:["need-input"]`
- **THEN** a `stdin` op delivers the input and the eval continues

#### Scenario: stdin when no eval blocked buffers input
- **WHEN** `stdin` is sent while no eval awaits input
- **THEN** payload is buffered in `stdin_channel` (capacity `max_stdin_buffer`, default 16); oldest entry dropped if full (REQ-RPL-017b)

### Requirement: close Operation
The server SHALL implement `close` to terminate a named session. Handled by `SessionMiddleware`. (REQ-RPL-018)

#### Scenario: Session closed successfully
- **WHEN** `{"op":"close","id":"8","session":"<id>"}` targets an existing session
- **THEN** response is `{"id":"8","status":["done","session-closed"]}`

#### Scenario: Close unknown session returns error
- **WHEN** `session` references a non-existent session
- **THEN** response is `{"status":["done","error","session-not-found"]}`

### Requirement: clone Operation
The server SHALL implement `clone` to create a new session, optionally copying state from a parent. Handled by `SessionMiddleware`. (REQ-RPL-036)

#### Scenario: Create empty session
- **WHEN** `{"op":"clone","id":"10"}` is sent without a `session` field
- **THEN** response is `{"id":"10","new-session":"<uuid>","status":["done"]}`

#### Scenario: Clone light to light deep-copies bindings
- **WHEN** `clone` is called with a `light` session as parent
- **THEN** a new session is created with deep-copied module bindings (REQ-RPL-036b)

#### Scenario: Non-serializable bindings skipped with warning
- **WHEN** a session has bindings that fail `deepcopy` (e.g., open file handles)
- **THEN** they are skipped and a warning is emitted as an `out` chunk in the clone response

#### Scenario: Heavy to light clone rejected
- **WHEN** `clone` is attempted from a `heavy` session to `light`
- **THEN** returns `{"status":["done","error"],"err":"Cannot clone heavy session to light: security boundary"}`

#### Scenario: Light to heavy clone creates new heavy session
- **WHEN** `clone` is called with a `light` session as parent and `"type":"heavy"`
- **THEN** a new heavy session is created (bindings are NOT copied across isolation boundaries); returns `{"new-session":"<uuid>","status":["done"]}`

#### Scenario: Clone to existing session rejected
- **WHEN** `clone` specifies a `name` that already exists
- **THEN** returns `{"status":["done","error","session-already-exists"],"err":"Session already exists: <name>"}`

#### Scenario: Clone during in-flight eval waits for eval mutex
- **WHEN** `clone` targets a session that has an active eval
- **THEN** the clone waits for the eval to complete (acquires eval mutex) before deep-copying bindings

### Requirement: ls-sessions Operation
The server SHALL implement `ls-sessions` to list all active sessions with their metadata. Handled by `SessionMiddleware`. (REQ-RPL-037)

#### Scenario: Sessions listed with metadata
- **WHEN** `{"op":"ls-sessions","id":"11"}` is sent
- **THEN** response includes `sessions` array with `id`, `type`, `created`, `last-activity` per session

### Requirement: Unknown Operation Fallback
If no middleware handles an `op`, the server SHALL respond with `{"status":["done","error","unknown-op"],"err":"Unknown operation: <op>"}`. (REQ-RPL-019)

#### Scenario: Unknown op returns unknown-op status
- **WHEN** a client sends `{"op":"frobnicate","id":"99"}`
- **THEN** response contains `"status":["done","error","unknown-op"]`

### Requirement: Malformed Input Handling
The server SHALL handle invalid JSON, missing `op`, missing `id`, and oversized messages without crashing. Oversized message enforcement is defined in `security/spec.md` (REQ-RPL-047e). Repeated malformed message disconnection is defined in `error-handling/spec.md` (REQ-RPL-020). (REQ-RPL-020)

#### Scenario: Invalid JSON response
- **WHEN** a line of non-JSON bytes arrives
- **THEN** the server logs the parse failure, counts it as a malformed message, and sends no response because no request `id` can be trusted for correlation

#### Scenario: Missing op returns error
- **WHEN** a request lacks the `op` field
- **THEN** response is `{"status":["done","error"],"err":"Missing required field: op"}`

#### Scenario: Missing id drops message
- **WHEN** a request lacks the `id` field
- **THEN** the server logs and drops the message (cannot correlate a response)
