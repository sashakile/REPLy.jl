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

## Error Handling

If a runtime error occurs during evaluation, REPLy catches it and returns a structured error response, including the stacktrace:

```bash
printf '%s\n' '{"op":"eval","id":"demo-err","code":"missing_name + 1"}' | nc 127.0.0.1 5555
```

## Graceful Shutdown

Call `close(server)` to stop the server. By default, REPLy allows up to 5 seconds for in-flight client tasks to finish before abandoning them. You can adjust the budget:

```julia
using REPLy

server = REPLy.serve(port=5555)

# Shut down with a 10-second grace window
Base.close(server; grace_seconds=10.0)
```

## Resource Limits

REPLy enforces two configurable safety limits that protect against runaway clients or evaluations.

### Inbound message size

Messages larger than `DEFAULT_MAX_MESSAGE_BYTES` (1 MiB) are rejected with a structured error and the connection is closed. To change the limit:

```julia
using REPLy

server = REPLy.serve(port=5555, max_message_bytes=512_000)  # 512 KiB
```

Oversized messages produce a `MessageTooLargeError` internally; clients receive a plain error response.

### Output truncation

Evaluation results larger than `DEFAULT_MAX_REPR_BYTES` (10 KiB) are truncated before being sent to the client. Truncated output is suffixed with `OUTPUT_TRUNCATION_MARKER` (`"…[truncated]"`). To change the limit, pass a custom `EvalMiddleware` to `serve`:

```julia
using REPLy
using REPLy: EvalMiddleware, SessionMiddleware

server = REPLy.serve(
    port=5555,
    middleware=[SessionMiddleware(), EvalMiddleware(; max_repr_bytes=100_000)],
)
```

## Development and Testing

If you are developing REPLy.jl or want to run the test suite:

- **Run Automated Tests**: `just test`
- **Run Smoke Tests**: `just smoke-test` (starts a temporary server, exercises an `eval` request, checks error paths, and verifies malformed JSON handling).
