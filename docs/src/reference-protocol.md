# Protocol Reference

REPLy uses a simple newline-delimited JSON protocol over TCP (or Unix socket). Each message is one JSON object per line. This page is the complete reference for the request/response contract.

## Request Envelope

Every request is a flat JSON object. Required fields:

| Field | Type | Description |
|---|---|---|
| `op` | string | Operation name (e.g., `"eval"`, `"new-session"`) |
| `id` | string | Client-assigned request ID, echoed in every response |

Optional fields (not all ops use all fields):

| Field | Type | Description |
|---|---|---|
| `session` | string | Name alias or UUID of the target named session |
| `code` | string | Julia code to evaluate (for `eval`) |
| `name` | string | Session name alias (for session ops) |

Keys must be kebab-case. Nested values and snake_case keys are rejected.

**Example:**

```json
{"op": "eval", "id": "req-1", "session": "main", "code": "x = 42"}
```

---

## Response Stream

Each request produces a **stream of response messages**, all with the same `"id"`. The stream is terminated by a message containing `"done"` in the `"status"` array.

### Success Response

A successful `eval` produces zero or more output messages, then a value message, then done:

**Request:**

```json
{"op": "eval", "id": "demo-1", "code": "println(\"hello\"); 1 + 1"}
```

**Response stream:**

```json
{"id": "demo-1", "out": "hello\n"}
{"id": "demo-1", "value": "2", "ns": "##EphemeralSession#1"}
{"id": "demo-1", "status": ["done"]}
```

Response message fields:

| Field | Type | When present |
|---|---|---|
| `id` | string | Always — echoes the request `id` |
| `out` | string | One or more stdout chunks before the final value |
| `err` | string | Stderr chunk (from `@warn`, etc.) — not a terminal error |
| `value` | string | `repr()` of the evaluated expression |
| `ns` | string | Module name the eval ran in |
| `status` | array | Terminal message only — contains `"done"` |

---

### Error Response

A runtime error produces a single message with both `"error"` and `"done"` in the status array:

**Request:**

```json
{"op": "eval", "id": "demo-err", "code": "missing_name + 1"}
```

**Response:**

```json
{
  "id": "demo-err",
  "status": ["done", "error"],
  "err": "UndefVarError: `missing_name` not defined",
  "ex": {
    "type": "UndefVarError",
    "message": "UndefVarError: `missing_name` not defined"
  },
  "stacktrace": [
    "top-level scope at REPL[1]:1",
    "..."
  ]
}
```

Error response fields:

| Field | Type | Description |
|---|---|---|
| `status` | array | Always contains `"done"` and `"error"` |
| `err` | string | Human-readable error message |
| `ex` | object | Structured exception with `type` and `message` |
| `stacktrace` | array | Array of stack frame strings |

**Client-side pattern — always check status before using value:**

```julia
status = get(response, "status", String[])
if "done" in status
    if "error" in status
        println("Error: ", get(response, "err", "unknown error"))
    else
        println("Result: ", get(response, "value", ""))
    end
end
```

---

## Status Flags

The `"status"` field is an array that may contain multiple flags. A message is terminal when it contains `"done"`. Clients must tolerate unknown flags (forward compatibility).

| Flag | Meaning |
|---|---|
| `"done"` | Terminal — stream is complete |
| `"error"` | Eval or protocol error occurred |
| `"unknown-op"` | The requested `op` is not supported |
| `"session-not-found"` | Named session does not exist |
| `"session-already-exists"` | Named session already exists (for `clone`) |
| `"session-limit-reached"` | Server-wide session cap reached |
| `"not-supported"` | Feature exists in spec but not yet implemented |
| `"path-not-allowed"` | File path rejected by server allowlist (`load-file`) |

---

## Session Operations

See [How-to: Manage Sessions](howto-sessions.md) for full examples. Quick reference:

| Op | Required fields | Optional fields | Returns |
|---|---|---|---|
| `new-session` | — | `name` | `session` (UUID), `name` |
| `ls-sessions` | — | — | `sessions` (array) |
| `clone` | `name` | `session` (source), `type` | `new-session` (UUID), `session`, `name` |
| `close` | `session` | — | bare `done` |

---

## Core Operations

Beyond `eval` and session management, REPLy provides several operations for introspection and code navigation.

### `describe`

Returns server capabilities, supported operations, and versions.

**Request:**
```json
{"op": "describe", "id": "desc-1"}
```

**Response:**
```json
{
  "id": "desc-1",
  "ops": {
    "eval": {"doc": "...", "returns": ["out", "err", "value", "ns"]},
    "complete": {"doc": "...", "requires": ["code", "pos"], "returns": ["completions"]},
    "..."
  },
  "versions": {"julia": "1.10.0", "reply": "0.1.0"},
  "encodings-available": ["json"],
  "encoding-current": "json",
  "status": ["done"]
}
```

### `load-file`

Loads and evaluates a Julia source file in the target session. Requires a server-side allowlist for security.

**Request:**
```json
{"op": "load-file", "id": "load-1", "file": "/path/to/script.jl", "session": "main"}
```

### `interrupt`

Interrupts an in-flight evaluation in a named session.

**Request:**
```json
{"op": "interrupt", "id": "int-1", "session": "main"}
```

**Response:**
```json
{"id": "int-1", "interrupted": ["main"], "interrupted-id": 42, "status": ["done"]}
```

### `complete`

Returns tab-completion candidates for a given code string and cursor position.

**Request:**
```json
{"op": "complete", "id": "comp-1", "code": "Base.prin", "pos": 9}
```

**Response:**
```json
{
  "id": "comp-1",
  "completions": [
    {"text": "print", "type": "Function"},
    {"text": "println", "type": "Function"}
  ],
  "status": ["done"]
}
```

### `lookup`

Returns documentation and method information for a symbol.

**Request:**
```json
{"op": "lookup", "id": "look-1", "symbol": "println"}
```

**Response:**
```json
{
  "id": "look-1",
  "found": true,
  "name": "println",
  "type": "Function",
  "doc": "println([io::IO], xs...)\n\nPrint and then a newline...",
  "methods": ["println(xs...) in Base at coreio.jl:4", "..."],
  "status": ["done"]
}
```

### `stdin`

Sends input to a session that is currently blocked on a `stdin` read (e.g., `readline()`).

**Request:**
```json
{"op": "stdin", "id": "in-1", "session": "main", "stdin": "user input\n"}
```

---

## Malformed Input

If the server receives a line that is not valid JSON, it closes the connection without sending any protocol response. This is intentional — there is no error message to echo an `id` from.

---

## Ordering Guarantees

Within a single request stream:

1. `out` / `err` chunks appear before the terminal `value`
2. `value` appears before `done`
3. Exactly one `done` is emitted per request

Responses from concurrent requests may interleave on the wire. Clients must use the `id` field to demultiplex.
