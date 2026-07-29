# Protocol Reference

> **TL;DR** — REPLy speaks newline-delimited JSON over TCP (or Unix sockets).
> Each request is a JSON object with `op` and `id` fields. Responses are a stream
> of JSON objects (same `id`), terminated by a `{"status":["done"]}` message.
> This page documents every operation, field, response shape, and status flag.

REPLy uses a simple newline-delimited JSON protocol over TCP (or Unix socket).
Each message is one JSON object per line. Clients open a socket, send requests,
and read a stream of response messages until they see the `"done"` status flag.
This page is the complete reference for the request/response contract.

> For a quick hands-on introduction, see the [Quick Start](index.md#quick-start).
> For a step-by-step client implementation, see the [Tutorial](tutorial-custom-client.md).

## Request Envelope

Every request is a flat JSON object. Required fields:

| Field | Type | Description |
|---|---|---|
| `op` | string | Operation name (e.g., `"eval"`, `"new-session"`) |
| `id` | string | Client-assigned request ID, echoed in every response |

Optional fields (not every op uses every field — the "Used by" column lists the ops that read each field):

| Field | Type | Used by | Description |
|---|---|---|---|
| `session` | string | `eval`, `stdin`, `interrupt`, `complete`, `load-file`, `reload-file`, `close`, `clone` | Name alias or UUID of the target named session. For `clone` it identifies the *source* session. |
| `code` | string | `eval`, `complete` | Julia source text to evaluate (`eval`) or complete (`complete`). |
| `name` | string | `new-session`, `clone` | Session name alias to create (`new-session`, `clone`); also accepted as a deprecated alias for `session` on `close`. |
| `module` | string | `eval`, `lookup` | Dotted module path to evaluate/resolve in (e.g. `"Base.Math"`). |
| `timeout-ms` | number | `eval` | Per-request deadline in ms. Capped at the server's `max_eval_time_ms` — clients may only tighten it. |
| `silent` | bool | `eval` | When `true`, suppress the `value` message (run for side effects only). Default `false`. |
| `store-history` | bool | `eval` | Whether to record the eval in session history. Default `true`. |
| `allow-stdin` | bool | `eval` | Whether the eval may block on `stdin` reads. Default `true`. |
| `pos` | number | `complete` | Cursor byte offset into `code` at which to complete. |
| `symbol` | string | `lookup` | Symbol name to look up documentation/methods for. |
| `file` | string | `load-file`, `reload-file` | Absolute path of the Julia file to load (subject to the server allowlist). |
| `input` | string | `stdin` | Text delivered to an eval currently blocked on a `stdin` read. |
| `interrupt-id` | number | `interrupt` | Specific in-flight eval id to cancel (defaults to the session's current eval). |
| `type` | string | `clone` | Clone strategy: `"light"` (default) or `"heavy"` (post-v1.0, returns `not-supported`). |
| `source` | string | `clone` | Deprecated compat alias for the source `session`. |
| `if-exists` | string | `new-session` | `"error"` (default) fails if `name` exists; `"reuse"` returns the existing session (idempotent). |
| `trusted` | bool | `new-session` | When `true`, back the session by `Main` instead of an anonymous module. Default `false`. |

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
| `"interrupted"` | Eval was cancelled by an `interrupt` op or server shutdown |
| `"timeout"` | Eval exceeded `max_eval_time_ms` and was cancelled (see [Evaluation timeout](index.md#Evaluation-timeout)) |
| `"concurrency-limit-reached"` | Eval rejected because `max_concurrent_evals` was reached — retry with backoff |
| `"session-not-found"` | Named session does not exist |
| `"session-already-exists"` | Named session already exists (for `clone`) |
| `"session-limit-reached"` | Server-wide session cap reached |
| `"not-supported"` | Feature exists in spec but not yet implemented |
| `"path-not-allowed"` | File path rejected by server allowlist (`load-file`) |
| `"pong"` | Response to a `ping` liveness probe |

---

## Session Operations

See [How-to: Manage Sessions](howto-sessions.md) for full examples. Quick reference:

| Op | Required fields | Optional fields | Returns |
|---|---|---|---|
| `new-session` | — | `name`, `if-exists`, `trusted` | `session` (UUID), `name` |
| `ls-sessions` | — | — | `sessions` (array) |
| `clone` | `name` | `session` (source), `source`, `type` | `new-session` (UUID), `session`, `name` |
| `close` | `session` | — | bare `done` |

**Response shapes** (each stream is terminated by a `"done"` message with the same `id`):

```json
// new-session
{"id": "new-1", "session": "f47ac10b-58cc-4372-a567-0e02b2c3d479", "name": "main"}
{"id": "new-1", "status": ["done"]}

// ls-sessions — `sessions` is an array of objects (see How-to for all fields)
{"id": "ls-1", "sessions": [
  {"session": "f47ac10b-...", "name": "main", "type": "light", "eval-count": 3}
]}
{"id": "ls-1", "status": ["done"]}

// clone — `new-session` carries the clone's UUID; `session` echoes it
{"id": "clone-1", "new-session": "a1b2c3d4-...", "session": "a1b2c3d4-...", "name": "experiment"}
{"id": "clone-1", "status": ["done"]}

// close — a bare terminal message
{"id": "close-1", "status": ["done"]}
```

---

## Protocol Operations (Core)

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
    "eval": {
      "doc": "Evaluate Julia code in a session module.",
      "requires": ["code"],
      "optional": ["session", "module", "timeout-ms", "allow-stdin", "silent", "store-history"],
      "returns": ["out", "err", "value", "repr-error", "ns", "ephemeral"]
    },
    "complete": {
      "doc": "Return tab-completions for Julia code.",
      "requires": ["code", "pos"],
      "optional": ["session"],
      "returns": ["completions"]
    }
  },
  "versions": {"julia": "1.10.0", "reply": "0.1.0"},
  "encodings-available": ["json"],
  "encoding-current": "json",
  "status": ["done"]
}
```

The `ops` map has one entry per supported operation. Each op descriptor carries `doc`
(string), `requires` (array of required request fields), `optional` (array of optional
request fields), and `returns` (array of response field names it may emit). The map is built
dynamically from the installed middleware stack, so it always reflects the ops this server
actually handles. Clients should treat unknown descriptor keys as forward-compatible.

### `load-file`

Loads and evaluates a Julia source file in the target session.

**Request:**
```json
{"op": "load-file", "id": "load-1", "file": "/path/to/script.jl", "session": "main"}
```

!!! warning "Allowlist required — default posture is deny-all"
    `load-file` and `reload-file` are each gated by a server-side allowlist (one per
    middleware). **With no allowlist configured, every path is rejected** with a
    `path-not-allowed` status — no files are accessible by default. An allowlist is a
    predicate `(path::String) -> Bool` supplied when you build the middleware; a rejected
    path never touches the filesystem.

    ```julia
    using REPLy
    stack = REPLy.default_middleware_stack()
    allow = p -> startswith(p, "/srv/project/")   # allow only this project tree
    # LoadFileMiddleware and ReloadFileMiddleware are configured independently:
    for T in (REPLy.LoadFileMiddleware, REPLy.ReloadFileMiddleware)
        idx = findfirst(m -> m isa T, stack)
        stack[idx] = T(; load_file_allowlist = allow)
    end
    server = REPLy.serve(port=5555, middleware=stack)
    ```

    Passing `load_file_allowlist = _ -> true` allows all paths and is **insecure** — any
    connected client can read/execute arbitrary files as your user.

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

### `ls-bindings`

Lists the user-defined bindings (name and type) in a session module, so an agent
resuming an existing session can discover its current state without re-running
eval history. Requires a `session`; auto-injected names (`eval`, `include`),
gensym names, sub-modules, and names brought into scope via `using` are excluded.

**Request:**
```json
{"op": "ls-bindings", "id": "lb-1", "session": "main"}
```

**Response:**
```json
{
  "id": "lb-1",
  "bindings": [
    {"name": "f", "type": "typeof(Main.var\"##REPLyNamedSession#1\".f)"},
    {"name": "x", "type": "Int64"}
  ],
  "count": 2,
  "ns": "##REPLyNamedSession#1",
  "status": ["done"]
}
```

Bindings are sorted by `name`. If the request has no `session`, an error response
is returned.

### `stdin`

Sends input to a session that is currently blocked on a `stdin` read (e.g., `readline()`).
The text to deliver goes in the `input` field.

**Request:**
```json
{"op": "stdin", "id": "in-1", "session": "main", "input": "user input\n"}
```

**Response:**
```json
{"id": "in-1", "delivered": ["main"]}
{"id": "in-1", "status": ["done"]}
```

The first message reports where the input went: `delivered` (with the session name) when an
eval was actively blocked on the read, or `buffered` when the input was queued for the
session's next `stdin` read.

### `ping`

Lightweight liveness probe. Returns a single terminal message with `"pong"` in the status
array, without looking up a session or running an eval.

**Request:**
```json
{"op": "ping", "id": "p-1"}
```

**Response:**
```json
{"id": "p-1", "status": ["done", "pong"]}
```

### `reload-file`

Re-includes a Julia source file into a named session, first clearing the stale top-level
module binding it defines so a subsequent `using .Mod` is unambiguous. Requires an existing
named `session` and is subject to its own server-side allowlist, like `load-file`. Does **not**
fix world-age issues for already-compiled methods.

**Request:**
```json
{"op": "reload-file", "id": "rl-1", "file": "/path/to/script.jl", "session": "main"}
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
