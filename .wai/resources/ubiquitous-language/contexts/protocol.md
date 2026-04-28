# Protocol Context

Scope: everything that crosses the wire — message shape, field names, encoding,
status flags, and ordering invariants. All other contexts depend on this one.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **Request Message** | Flat JSON object sent by a client. Required fields: `op`, `id`. Optional: `session` and operation-specific fields. |
| **Response Message** | Flat JSON object sent by the server. Always echoes the request `id`. |
| **Message Envelope** | The flat nREPL-style shape shared by all messages. Not JSON-RPC 2.0. No nested objects. |
| **Request ID** (`id`) | Client-generated opaque correlation handle. 1–256 bytes. Unique per connection, not globally. |
| **Session ID** | Server-generated UUIDv4 string. Identifies a persistent session. Created with a cryptographically-secure RNG to prevent prediction. |
| **Operation** (`op`) | String name of the action requested (`eval`, `complete`, `describe`, …). Routes through the middleware stack. |
| **Status Flag** | String token in the `status` array of a response. Signals outcome or state (see table below). |
| **Response Stream** | All response messages that share the same `id`, from first response until (and including) the `done` message. |
| **Terminal Response** | The final message in a response stream. Canonical definition: **a response message whose `status` array contains `"done"`**. No response is ever sent after the terminal response for a given `id`. Synonyms found in code comments — "done message", "final response" — all mean the same thing; this spec uses *terminal response* exclusively. |
| **Wire Format** | Serialisation used on the connection. Default: newline-delimited JSON. Optional: length-prefixed JSON, MessagePack. |
| **Encoding** | Synonym for *wire format* when discussing per-listener configuration. Chosen at connection time; not negotiable mid-connection. |

## Status Flags

| Flag | Meaning | Terminal? |
|------|---------|-----------|
| `done` | Response stream is complete. | Yes |
| `error` | Operation failed. | No (combine with `done`) |
| `interrupted` | Eval was stopped by an `interrupt` request. Not classified as `error`. | No (combine with `done`) |
| `need-input` | Eval is blocked waiting for a `stdin` message. | No |
| `session-not-found` | Requested session does not exist. | No (combine with `done`, `error`) |
| `session-closed` | Session was closed during processing. | No (combine with `done`, `error`) |
| `session-already-exists` | Clone attempted to create a session whose name is already taken. | No (combine with `done`, `error`) |
| `session-limit-reached` | Cannot create a new session; server-wide cap hit. | No (combine with `done`, `error`) |
| `concurrency-limit-reached` | Eval queue is full; request rejected. | No (combine with `done`, `error`) |
| `rate-limited` | Connection has exceeded the per-minute request cap. | No (combine with `done`, `error`) |
| `timeout` | Eval exceeded the wall-clock deadline. | No (combine with `done`, `error`) |
| `path-not-allowed` | `load-file` path is outside the configured allowlist. | No (combine with `done`, `error`) |
| `unknown-op` | No middleware handles the requested `op`. | No (combine with `done`, `error`) |
| `unauthorized` | Request lacks valid authentication (post-v1.0). | No (combine with `done`, `error`) |

## Operations (top-level vocabulary)

| Op | Description |
|----|-------------|
| `describe` | Advertise server capabilities, ops, middleware, versions, available encodings. |
| `eval` | Evaluate Julia code in a session; streams stdout/stderr before returning a value. |
| `load-file` | Read a file from disk and evaluate its contents. |
| `interrupt` | Stop an in-flight evaluation. |
| `complete` | Return tab-completion candidates at a cursor position. |
| `lookup` | Resolve symbol documentation and method signatures. |
| `stdin` | Deliver text to an eval that is blocked on `readline()`. |
| `clone` | Create a new session, optionally copying state from a parent. |
| `close` | Terminate a named session. |
| `ls-sessions` | List all active persistent sessions with metadata. |

## `ls-sessions` Response Shape

`ls-sessions` returns one terminal response message:

```json
{
  "id":       "<request-id>",
  "sessions": [
    {
      "id":           "<session-uuid>",
      "alias":        "<alias-or-null>",
      "state":        "idle | running | closed",
      "last-active":  "<ISO-8601 timestamp>"
    }
  ],
  "status": ["done"]
}
```

- `sessions` is an array; empty array `[]` when no named sessions exist.
- Ephemeral sessions are never included.
- `alias` is `null` when none was set.
- `state` maps directly to the **Session State** enum in the Session context.

## Ordering Invariant

Within a single response stream (same `id`):

```
stdout/stderr chunks  →  value  →  done
```

No `value` or `done` is emitted before all output chunks for that request.

## Conventions

- All field names use **kebab-case** (e.g., `new-session`, `timeout-ms`, `store-history`). Never snake_case.
- The envelope is **flat**: no nested JSON objects. All values are scalars or arrays of scalars.
- Unknown fields in a request are **silently ignored** by the server.
- Unknown status flags in a response are **silently ignored** by the client.
