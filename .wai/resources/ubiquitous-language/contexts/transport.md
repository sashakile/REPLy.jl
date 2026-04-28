# Transport Context

Scope: the network layer — sockets, connections, encoding, and the
send/receive loop. Middleware and sessions have no dependency on this context.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **Transport** | Abstract interface for sending and receiving messages. Methods: `send!`, `receive`, `close`, `isopen`. Decoupled from session and middleware logic. |
| **JSON Transport** | Concrete transport over newline-delimited JSON. One message per line, UTF-8. |
| **Length-Prefixed Transport** | Optional format: 4-byte big-endian `UInt32` byte count followed by UTF-8 JSON. |
| **MessagePack Transport** | Optional binary format (deferred; not normative in v1.0). |
| **Listener** | A configured transport endpoint: either a TCP host+port or a Unix domain socket path. A server may have multiple listeners active simultaneously. |
| **Server Socket** | The OS-level listening socket bound to a listener's address. Accepts incoming connections. |
| **Client Connection** | Per-client state: UUID, transport instance, receiver task, send channel, active flag. |
| **Connection Handler** | Per-client `Task` that runs the receive → dispatch → send loop for the lifetime of a connection. |
| **Send Channel** | `Channel{Dict}` buffering outbound responses. Allows async, non-blocking sends. One per client connection. |
| **Receiver Task** | `Task` blocking on `receive(transport)`. Queues inbound messages for dispatch. |
| **Socket Path** | File-system path for a Unix domain socket. Removed at server startup if a stale file exists. |
| **Encoding** | The wire format agreed upon for a listener. Chosen at connection time by URL scheme or per-listener config. Not negotiable after the connection is established. |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Send** | `send!(transport, msg)` — serialize `msg` to the configured encoding + newline; write to IO under a lock. |
| **Receive** | `receive(transport)` — read one message; return parsed `Dict` or `nothing` on clean EOF/disconnect. Never throws on disconnect. |
| **Listen** | Bind server socket to a listener's address; begin accepting connections. |
| **Accept** | Server picks up a new connection from the OS; spawns a `Connection Handler` task. |
| **Dispatch** | Pass a received message through the middleware stack; collect all response messages. |
| **Send Response** | Push a response dict onto the `Send Channel`; silently discard if the channel is closed (never propagate `InvalidStateException`). |
| **Close Transport** | Close the underlying IO stream. |
| **Check Open** | `isopen(transport)` — report whether the connection is still active. |

## Wire Formats

| Format | Description | Status |
|--------|-------------|--------|
| Newline-Delimited JSON | One JSON object per line (`\n`). UTF-8. | Default; v1.0 |
| Length-Prefixed JSON | 4-byte big-endian length + UTF-8 JSON bytes. | Optional; v1.0 |
| MessagePack | Binary encoding. | Deferred; post-v1.0 |

**Encoding selection**: negotiated by URL scheme (e.g., `reply+json://…`, `reply+msgpack://…`) or per-listener server configuration. Cannot be changed mid-connection.

## Multi-Listener Rules

- A single server may bind TCP and Unix socket listeners simultaneously.
- Resource limits (`max_sessions`, `max_concurrent_evals`, `rate_limit_per_min`) are **global** — shared across all listeners.
- Each listener may use a different encoding.

## Invariants

- **Partial read** — `receive()` returns `nothing` (not an exception) when the client disconnects mid-message.
- **Resilient send** — if the send channel is closed when a response arrives, the response is silently dropped. The server never crashes due to a closed client channel.
- **Message Frame** — each JSON message is bounded by a newline; respects UTF-8 codepoint boundaries (never splits a multi-byte character).
