## Tracer Bullet Scope

A tracer bullet cuts through every architectural layer with the thinnest working slice.

### Target: eval over TCP

Client connects via TCP, sends:
```json
{"op":"eval","id":"1","code":"1+1"}
```
Gets back a two-message stream:
```json
{"id":"1","value":"2","ns":"Main"}
{"id":"1","status":["done"]}
```
Each message is a separate newline-delimited JSON object. The `done` message
is always the final message in the stream.

### Layers exercised

1. **Transport** — TCP listener on configurable port (default 5555)
2. **Protocol** — Newline-delimited JSON framing, flat envelope
3. **Middleware** — Minimal 3-middleware subset of the default 9-middleware stack: SessionMiddleware → EvalMiddleware → UnknownOpMiddleware. The remaining 6 (DescribeMiddleware, InterruptMiddleware, LoadFileMiddleware, CompletionMiddleware, LookupMiddleware, StdinMiddleware) are deferred — each adds an operation but doesn't change the pipeline architecture.
4. **Session** — Ephemeral session (anonymous Module, auto-created when no session field)
5. **Core-operations** — `Core.eval` in session module, stdout/stderr capture, value repr
6. **Error handling** — Malformed JSON closes the TCP boundary without a protocol response; unknown op and eval errors use structured error messages with ex/stacktrace
7. **Protocol invariants** — id echo, done-terminated stream, kebab-case keys

### What's deliberately OUT of scope

- Unix socket transport (additive, same interface)
- Persistent sessions / clone / close / ls-sessions (SessionMiddleware handles ephemeral only)
- Interrupt, complete, lookup, load-file, stdin operations
- describe operation (trivial to add later)
- Resource limits enforcement (timeout, memory, rate limiting)
- Security (permissions, audit logging)
- MCP adapter
- Heavy sessions (Malt.jl)
- MessagePack encoding

### Key spec requirements touched

- REQ-RPL-001 (flat JSON envelope)
- REQ-RPL-002 (message id)
- REQ-RPL-005 (newline-delimited JSON)
- REQ-RPL-011 (eval operation)
- REQ-RPL-030 (light session via anonymous Module)
- REQ-RPL-040 (TCP transport)
- REQ-RPL-050 (middleware pipeline)
- REQ-RPL-061 (error response format)
