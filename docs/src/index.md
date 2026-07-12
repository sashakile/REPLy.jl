# REPLy.jl

!!! warning "LLM-generated code"
    This project is entirely LLM-generated code. It has not been manually reviewed or audited. Use at your own risk.

**REPLy.jl** is a network REPL server for Julia. It exposes a Julia session over a socket-based protocol (newline-delimited JSON), allowing editors, IDEs, and other tooling to connect, evaluate code, and inspect results interactively — similar to [nREPL](https://nrepl.org/) for Clojure.

See also: [Status](status.md) for current implementation details and spec conformance, and [API](api.md) for the Julia API reference.

## Installation

You can install REPLy.jl using Julia's package manager:

```julia
using Pkg
Pkg.add("REPLy")
```

## Quick Start

### 1. Start the Server

Start a REPLy server on a local port (default is `5555`):

```julia
using REPLy

# Start a server on 127.0.0.1:5555
server = REPLy.serve(port=5555)
println("REPLy listening on port $(REPLy.server_port(server))")

# Keep the Julia process alive
wait(Condition())
```

!!! tip "Use REPLy like Revise"
    For a much smoother workflow, you can configure REPLy to start automatically in every interactive session. See [How-to: REPLy as a Global Dev Tool](howto-dev-tool.md).

### 2. Connect and Evaluate Code

Clients communicate with REPLy by sending newline-delimited JSON messages over TCP.

You can test this from a terminal using `nc` (netcat):

```bash
printf '%s\n' '{"op":"eval","id":"demo-1","code":"println(\"hello\"); 1 + 1"}' | nc 127.0.0.1 5555
```

You will receive a stream of JSON responses. REPLy forwards standard output, the evaluated result, and a final `done` status:

```json
{"id":"demo-1","out":"hello\n"}
{"id":"demo-1","value":"2","ns":"##REPLySession#..."}
{"id":"demo-1","status":["done"]}
```

!!! note "Ephemeral by default"
    Every `eval` request runs in a fresh, isolated session — variables do not persist between requests. For persistent state across evals (editor integration, REPL workflows), see [How-to: Manage Sessions](howto-sessions.md).

## Error Handling

If a runtime error occurs during evaluation, REPLy catches it and returns a structured error response, including the stacktrace:

```bash
printf '%s\n' '{"op":"eval","id":"demo-err","code":"missing_name + 1"}' | nc 127.0.0.1 5555
```

See [Protocol Reference](reference-protocol.md) for the full error response shape and all status flags.

## Graceful Shutdown

Call `close(server)` to stop the server. By default, REPLy allows up to 5 seconds for in-flight client tasks to finish before abandoning them. You can adjust the budget:

```julia
using REPLy

server = REPLy.serve(port=5555)

# Shut down with a 10-second grace window
Base.close(server; grace_seconds=10.0)
```

## Security Model

REPLy is a **local developer tool** — it carries no built-in authentication. Any client that can reach the server can execute arbitrary Julia code in your process.

**Default TCP binding** (`host=ip"127.0.0.1"`) listens only on the loopback interface, so only processes on the same machine can connect. If you override `host` to a non-loopback address, REPLy will log a startup warning.

For multi-user machines or any situation where you want OS-level access control, use a Unix domain socket instead of TCP:

```julia
server = REPLy.serve(socket_path="/tmp/reply-$(getpid()).sock")
```

Unix sockets are created with `chmod 600` (owner read/write only), so only your own processes can connect.

!!! warning "No authentication over TCP"
    Do not expose a REPLy TCP server on a network-facing interface without an external access-control layer (firewall rule, VPN, SSH tunnel). There is no password, token, or TLS support in v1.x.

## Resource Limits

REPLy enforces several configurable safety limits that protect against runaway clients or evaluations. Message size and output truncation are set on `serve`; the remaining limits live on a [`ResourceLimits`](api.md) value passed as `serve(...; limits=ResourceLimits(...))`.

### Inbound message size

Messages larger than `DEFAULT_MAX_MESSAGE_BYTES` (1 MiB) are rejected with a structured error and the connection is closed. To change the limit:

```julia
using REPLy

server = REPLy.serve(port=5555, max_message_bytes=512_000)  # 512 KiB
```

Oversized messages produce a `MessageTooLargeError` internally; clients receive a plain error response.

### Output truncation

Evaluation results larger than `DEFAULT_MAX_REPR_BYTES` (10 KB) are truncated before being sent to the client. Truncated output is suffixed with `OUTPUT_TRUNCATION_MARKER` (`"…[truncated]"`). To change the limit, pass a custom `REPLy.EvalMiddleware` to `serve`:

!!! warning "Passing `middleware=` replaces the full stack"
    The `middleware` keyword replaces the *entire* default stack, which includes session,
    session-ops, describe, interrupt, stdin, eval, and unknown-op handlers. Passing only
    `[SessionMiddleware(), EvalMiddleware()]` silently drops all other handlers.

    To customise a single element, build from the default stack and swap the target entry:

    ```julia
    using REPLy

    stack = REPLy.default_middleware_stack()
    idx = findfirst(m -> m isa REPLy.EvalMiddleware, stack)
    stack[idx] = REPLy.EvalMiddleware(; max_repr_bytes=100_000)
    server = REPLy.serve(port=5555, middleware=stack)
    ```

`REPLy.default_middleware_stack`, `REPLy.SessionMiddleware`, and `REPLy.EvalMiddleware` are
lower-level embedding APIs rather than part of the minimal exported API surface.

### Evaluation timeout

Every `eval` is capped at `max_eval_time_ms` (default **30 000 ms**, i.e. 30 s) of wall-clock time. When an eval exceeds the cap, REPLy interrupts it and returns a terminal error whose `status` contains `"timeout"`. The response also carries the effective limit and a hint so the cap is discoverable:

```json
{
  "id": "slow-1",
  "status": ["done", "error", "timeout"],
  "err": "eval timed out after 30000 ms",
  "max-eval-time-ms": 30000,
  "hint": "eval exceeded max_eval_time_ms; raise the max_eval_time_ms resource limit to allow longer evaluations"
}
```

Raise (or lower) the server-wide cap via `ResourceLimits`:

```julia
using REPLy

server = REPLy.serve(port=5555, limits=REPLy.ResourceLimits(max_eval_time_ms=120_000))  # 2 min
```

A client may also request a shorter deadline per request with the `timeout-ms` field, but a per-request value is **capped** at the server's `max_eval_time_ms` — clients cannot extend the server limit, only tighten it.

### Concurrency backpressure

At most `max_concurrent_evals` evals (default **10**) run at once server-wide. REPLy does **not** queue excess work: when the limit is reached, additional `eval` requests are rejected immediately with a terminal error whose `status` contains `"concurrency-limit-reached"`:

```json
{
  "id": "burst-42",
  "status": ["done", "error", "concurrency-limit-reached"],
  "err": "Too many concurrent evals"
}
```

Because rejected requests are shed rather than buffered, clients that issue bursts of concurrent evals should **retry with backoff** on this flag. Tune the ceiling to match your workload:

```julia
using REPLy

server = REPLy.serve(port=5555, limits=REPLy.ResourceLimits(max_concurrent_evals=32))
```

## Next Steps

The `nc` example above is useful for exploration. For persistent editor integration — where you keep a connection open and eval code on demand — copy the ready-to-use client recipe from the [Tutorial: Building a Custom Client](tutorial-custom-client.md).

## Development and Testing

If you are developing REPLy.jl or want to run the test suite:

- **Run Automated Tests**: `just test`
- **Run Smoke Tests**: `just smoke-test` (starts a temporary server, exercises an `eval` request, checks error paths, and verifies malformed JSON handling).
