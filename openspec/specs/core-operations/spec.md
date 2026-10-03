---
id: spec
kind: intent
statement: "WHEN a client invokes a built-in Reply protocol operation, THE server SHALL execute describe, eval, load-file, interrupt, complete, lookup, stdin, close, clone, and ls-sessions with validated options, ordered response streams, bounded values, and tolerant fallbacks for unknown or malformed operations."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| OPS_COMPLETE | invariant | every built-in operation (`describe`, `eval`, `load-file`, `interrupt`, `complete`, `lookup`, `stdin`, `close`, `clone`, `ls-sessions`) is answered with a well-formed response carrying the request id, and every op descriptor in `describe` names its `doc`, `requires`, `optional`, and `returns` fields | [[spec]] |
| EVAL_STREAM_ORDER | invariant | every eval stream emits stdout/stderr chunks before the `value` message, which precedes the single terminating `done`; `silent` omits the `value` frame but keeps `out`, `err`, and error responses | [[spec]] |
| EVAL_OPTIONS_VALIDATED | invariant | per-eval options are validated before execution: `timeout-ms` below 1 is rejected, a larger value is silently capped at `max_eval_time_ms`, an unresolvable `module` path returns an error naming the path, and `store-history:false` skips both the `ans` binding and the session history vector | [[spec]] |
| VALUE_REPR_BOUNDED | invariant | the `value` field is `repr(result)`; when it exceeds `max_value_repr_bytes` it is cut at the limit with the `\n…[truncated to N bytes]` suffix and the terminal `done` carries `truncated:true` | [[spec]] |
| LOAD_FILE_GUARDED | invariant | `load-file` executes only allowlisted readable files, reports classified errors (`path-not-allowed`, `file-not-found`) without leaking the file path, and propagates file/line for stack traces | [[spec]] |
| INTERRUPT_IS_IDEMPOTENT | invariant | interrupting a running eval terminates its stream with `status:["done","interrupted"]` and names the session in `interrupted`; interrupting a completed eval (matched or not by `interrupt-id`) is a no-op success with `interrupted:[]`; an omitted `interrupt-id` cancels all in-flight evals of the session | [[spec]] |
| STDIN_DELIVERY | invariant | `stdin` input is delivered to a named session's eval waiting on input (reported in `delivered`) or buffered in the bounded `stdin_channel` (capacity `max_stdin_buffer`, default 16) whose oldest entry is dropped when full (reported in `buffered`) | [[spec]] |
| CLONE_ISOLATION | invariant | `clone` creates a fresh named session — copying bindings only when a parent is given; light parents deep-copy bindings (skipping non-copyable ones with a warning `out` chunk), heavy clone types are rejected with `Heavy sessions require Malt.jl` (REQ-RPL-033 v1.2), destination alias collisions return `session-already-exists`, and a clone of a session with an in-flight eval waits for the eval to complete before copying | [[spec]] |
| MALFORMED_TOLERATED | invariant | invalid JSON lines are logged and counted with no response; a missing `op` returns `op is required`; a missing or empty `id` returns `id must not be empty` with an empty response id; an unknown op returns `unknown-op` status naming the op | [[spec]] |

## Model

### States

- `awaiting`
- `validated`
- `executing`
- `terminal`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| receive_op | awaiting | validated | [[spec.OPS_COMPLETE]] ∧ [[spec.MALFORMED_TOLERATED]] |
| execute_op | validated | executing | [[spec.EVAL_OPTIONS_VALIDATED]] ∧ [[spec.LOAD_FILE_GUARDED]] |
| emit_stream | executing | terminal | [[spec.EVAL_STREAM_ORDER]] ∧ [[spec.VALUE_REPR_BOUNDED]] |
| next_request | terminal | awaiting | [[spec.STDIN_DELIVERY]] ∧ [[spec.CLONE_ISOLATION]] ∧ [[spec.INTERRUPT_IS_IDEMPOTENT]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| describe_shape_holds | unit | [[spec.OPS_COMPLETE]] | `test/unit/core_operations_spec_test.jl` | a `describe` response carries `ops` (with eval/clone/close/complete/lookup/interrupt/ls-sessions/stdin/load-file and full descriptor fields), `versions` (`julia`, `reply`), `encodings-available`, `encoding-current`, and `status:["done"]` |
| eval_stream_ordering_holds | unit | [[spec.EVAL_STREAM_ORDER]] | `test/unit/core_operations_spec_test.jl` | success returns value then done; stdout chunks precede the value; empty code returns `nothing`; silent suppresses the value frame while out and done still arrive |
| eval_options_honored | unit | [[spec.EVAL_OPTIONS_VALIDATED]] | `test/unit/core_operations_spec_test.jl` | dotted module paths route into the named module (ns reports it), unresolvable paths error naming the path, allow-stdin:false makes byte reads raise EOFError, timeout-ms below 1 is rejected, oversized timeouts are capped, and store-history:false leaves ans and the history vector untouched while a default eval updates both |
| value_truncation_flagged | unit | [[spec.VALUE_REPR_BOUNDED]] | `test/unit/core_operations_spec_test.jl` | a value repr over the limit ends with `\n…[truncated to N bytes]` and its done carries `truncated:true`; a small value is untruncated with no flag |
| load_file_guarded | unit | [[spec.LOAD_FILE_GUARDED]] | `test/unit/core_operations_spec_test.jl` | an allowlisted file is evaluated with its bindings landing in the session module, a denied path returns `path-not-allowed`, and an unreadable file returns `file-not-found` without leaking the path |
| interrupt_semantics_hold | unit | [[spec.INTERRUPT_IS_IDEMPOTENT]] | `test/unit/core_operations_spec_test.jl` | a running eval interrupted by id terminates with done+interrupted, a completed eval interrupt is a no-op success with `interrupted:[]`, and an omitted interrupt-id cancels the session's in-flight eval |
| stdin_delivered_or_buffered | unit | [[spec.STDIN_DELIVERY]] | `test/unit/core_operations_spec_test.jl` | stdin delivered to a blocked readline unblocks the eval with the delivered line; buffering past capacity drops the oldest entry so the next eval reads from the new front |
| clone_semantics_hold | unit | [[spec.CLONE_ISOLATION]] | `test/unit/core_operations_spec_test.jl` | a parentless clone creates an empty usable session, light clones deep-copy bindings (child mutation leaves the parent unchanged), non-copyable bindings are skipped with a warning out chunk, heavy types are rejected with the Malt.jl error, alias collisions return `session-already-exists`, and a clone during an in-flight eval waits so end-of-eval bindings are copied |
| malformed_input_tolerated | unit | [[spec.MALFORMED_TOLERATED]] | `test/unit/core_operations_spec_test.jl` | an unparsable JSON line gets no response and the connection stays usable, a missing op returns `op is required`, a missing id returns `id must not be empty` with an empty response id, and unknown ops return the unknown-op flag naming the operation |

# Core Operations

_Version: 1.2 — 2026-10-04_

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
- **THEN** the server returns a `value` frame with `"value":"2"` and `ns` naming the eval module, followed by `{"status":["done"]}`

#### Scenario: Eval with stdout
- **WHEN** code calls `println("hello")`
- **THEN** the server emits `{"out":"hello\n"}` before the `value` message

#### Scenario: Empty code returns nothing
- **WHEN** code is the empty string `""`
- **THEN** the server returns a `value` frame with `"value":"nothing"` then `{"status":["done"]}` (REQ-RPL-011b)

#### Scenario: Dotted module path resolved
- **WHEN** `module` is a dotted path rooted at an unprotected top-level module (e.g. `"Foo.Bar"` with `Foo.Bar` existing in `Main`; `Main`/`Base`/`Core` roots are blocked)
- **THEN** eval runs in that module and the response `ns` names it (REQ-RPL-011c)

#### Scenario: Unresolvable module returns error
- **WHEN** `module` is `"Main.DoesNotExist"`
- **THEN** the server returns `{"status":["done","error"],"err":"Cannot resolve module: ..."}` (REQ-RPL-011c)

#### Scenario: allow-stdin false causes EOFError
- **WHEN** `allow-stdin` is `false` and code performs a byte-requiring stdin read such as `read(stdin, UInt8)`
- **THEN** the call raises `EOFError` immediately (bare `readline()` returns `""` at EOF without raising — Julia EOF semantics per REQ-RPL-073) (REQ-RPL-011d)

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
- **THEN** returns a classified error — `{"status":["done","error","file-not-found"],"err":"File not found"}` — without leaking the file path in the error message

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
- **WHEN** an eval is waiting on `readline()` and a `stdin` op targets its session (the stdin response marks it in `delivered`)
- **THEN** the input is delivered and the blocked eval continues with the delivered line

#### Scenario: stdin when no eval blocked buffers input
- **WHEN** `stdin` is sent while no eval awaits input
- **THEN** payload is buffered in `stdin_channel` (capacity `max_stdin_buffer`, default 16); oldest entry dropped if full (REQ-RPL-017b)

### Requirement: close Operation
The server SHALL implement `close` to terminate a named session. Handled by `SessionMiddleware`. (REQ-RPL-018)

#### Scenario: Session closed successfully
- **WHEN** `{"op":"close","id":"8","session":"<id>"}` targets an existing session
- **THEN** the response is `{"id":"8","status":["done"]}` and subsequent requests to the session return `session-not-found`

#### Scenario: Close unknown session returns error
- **WHEN** `session` references a non-existent session
- **THEN** response is `{"status":["done","error","session-not-found"]}`

### Requirement: clone Operation
The server SHALL implement `clone` to create a new session, optionally copying state from a parent. Handled by `SessionMiddleware`. A `clone` without a `session`/`source` field creates a fresh empty session. (REQ-RPL-036)

#### Scenario: Create empty session
- **WHEN** `{"op":"clone","id":"10"}` is sent without a `session` field
- **THEN** response is `{"id":"10","new-session":"<uuid>","status":["done"]}`

#### Scenario: Clone light to light deep-copies bindings
- **WHEN** `clone` is called with a `light` session as parent
- **THEN** a new session is created with deep-copied module bindings (REQ-RPL-036b)

#### Scenario: Non-serializable bindings skipped with warning
- **WHEN** a session has bindings that fail `deepcopy` (e.g., open file handles)
- **THEN** they are skipped and a warning is emitted as an `out` chunk in the clone response

#### Scenario: Heavy clone rejected without Malt.jl
- **WHEN** `clone` includes `"type":"heavy"` (from any parent, or with no parent) and Malt.jl is not loaded
- **THEN** returns `{"status":["done","error"],"err":"Heavy sessions require Malt.jl"}` and no destination session is created (REQ-RPL-033 v1.2 alignment with session-management)

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
- **THEN** response includes a `sessions` array with `session` (the UUID id), `name`, `type`, `created`, and `last-activity` per session

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
- **THEN** response is `{"status":["done","error"],"err":"op is required"}`

#### Scenario: Missing id returns validation error
- **WHEN** a request lacks the `id` field
- **THEN** the server responds `{"id":"","status":["done","error"],"err":"id must not be empty"}` — no eval runs because nothing can be correlated
