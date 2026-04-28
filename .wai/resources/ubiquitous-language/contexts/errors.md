# Errors Context

Scope: the taxonomy of failures, how they are structured in responses, and
how clients should distinguish them. This is not about "exceptions in Julia"
but about the protocol-level error vocabulary.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **Error Response** | A terminal response that includes `"error"` in its `status` array, plus an `err` summary string, an `ex` object, and a `stacktrace` array. |
| **Parse Error** | Failure from `Meta.parseall(code)` on invalid Julia syntax. No eval was attempted. |
| **Runtime Error** | Any exception raised during `Core.eval`. Includes exception type, message, and stacktrace. |
| **Exception Type** (`ex.type`) | String name of the Julia exception class (e.g., `"UndefVarError"`, `"DivideError"`). |
| **Exception Message** (`ex.message`) | Human-readable string extracted from the exception. Safe fallback via `sprint(showerror, ex)` if no `.msg` field. |
| **Stacktrace Payload** | Array of frame dicts, each with `func`, `file`, and `line` fields. May be empty for some exception types. |
| **Error Summary** (`err`) | Short human-readable description of the failure. Used as the top-level error string in error responses. |
| **Interrupted** | Outcome when an eval is stopped by `interrupt`. Status: `["done","interrupted"]`. **Not** an error. |
| **Malformed Message** | A received message that is not valid JSON, lacks `op`, lacks `id`, or has `id` longer than `max_id_length`. |
| **Malformed Message Counter** | Per-connection count of consecutive malformed messages. Connection is closed after 10 consecutive failures. The threshold 10 is an implementation constant (not user-configurable); its purpose is to tolerate transient encoding glitches from well-behaved clients while preventing abuse. The counter resets to 0 after any valid message. |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Build Error Response** | Construct the error response dict: `{ id, err, ex: {type, message}, stacktrace: […], status: ["done","error",…] }`. |
| **Catch Exception** | Wrap `Core.eval` in `try/catch`; format the exception into an error response. |
| **Extract Exception Message** | Check `hasfield(typeof(ex), :msg)` before accessing `.msg`; fall back to `sprint(showerror, ex)`. |
| **Serialize Stacktrace** | Convert `catch_backtrace()` frames to `[{func, file, line}, …]`. Truncate safely for very large traces. |
| **Handle Interrupt** | Catch `InterruptException`; emit `status: ["done","interrupted"]` — no `"error"` flag. |
| **Handle Timeout** | Catch `TimeoutError`; emit `status: ["done","error","timeout"]`. |
| **Validate Request** | Check `id` presence, length, `op` presence, flat envelope shape. Return malformed error if invalid. |
| **Ignore Unknown Fields** | Silently discard any request fields the server does not recognise. |
| **Ignore Unknown Status Flags** | Clients silently discard any status flag they do not recognise. |
| **Close on Repeated Malformed** | After 10 consecutive malformed messages (counter never reset by a valid message in between), close the connection. A valid message at any point resets the counter to 0. |

## Error Response Shape

```json
{
  "id":         "<request-id>",
  "err":        "<short summary>",
  "ex": {
    "type":     "UndefVarError",
    "message":  "x not defined"
  },
  "stacktrace": [
    { "func": "eval", "file": "REPL[1]", "line": 1 }
  ],
  "status":     ["done", "error"]
}
```

## Disambiguation: `err` Field

The field name `err` appears in two distinct contexts:

| Context | `status` contains `"error"`? | Meaning |
|---------|------------------------------|---------|
| Stderr chunk | No | A fragment of text written to stderr during eval. Not a failure. |
| Error summary | Yes | Short description of why the operation failed. |

Clients MUST check `status` to distinguish these two uses.

## Interrupted ≠ Error

`status: ["done","interrupted"]` means the eval was explicitly stopped.
It does NOT contain `"error"`. A client MUST NOT treat it as a failure.

## Error Category Taxonomy

| Status Flag | Cause |
|-------------|-------|
| `error` | Generic failure (parse, runtime, etc.) |
| `timeout` | Eval exceeded `max_eval_time_ms` |
| `interrupted` | Explicit interrupt (no `"error"`) |
| `session-not-found` | Requested session UUID/alias does not exist |
| `session-closed` | Session was closed during the operation |
| `session-already-exists` | Clone target alias already taken |
| `session-limit-reached` | `max_sessions` cap reached |
| `concurrency-limit-reached` | Eval queue full |
| `rate-limited` | Per-connection rate cap exceeded |
| `path-not-allowed` | `load-file` path outside allowlist |
| `unknown-op` | No middleware handles the requested op |
| `unauthorized` | Missing/invalid auth token (post-v1.0) |
