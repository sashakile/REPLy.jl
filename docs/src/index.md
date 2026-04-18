# REPLy.jl

!!! warning "LLM-generated code"
    This project is entirely LLM-generated code. It has not been manually reviewed or audited. Use at your own risk.

REPLy.jl is a network REPL server for Julia — think [nREPL](https://nrepl.org/) for Clojure, but for Julia. It exposes a Julia REPL over a socket-based protocol so that editors and tooling can connect, evaluate code, and inspect results interactively.

See also: [Status](status.md) for an implementation, coverage, and spec-conformance view of the current system.

## Current Status

The current tracer-bullet implementation supports:

- a TCP server started with `REPLy.serve`
- newline-delimited JSON messages
- request validation for flat, kebab-case envelopes
- the `eval` operation
- buffered `stdout` / `stderr` forwarding
- structured error responses
- concurrent clients
- closing malformed-JSON connections without sending a protocol response

## Automated Testing

```bash
just test
```

At the moment, the full test suite passes locally.

## Smoke Test Script

```bash
just smoke-test
```

This starts a temporary server, exercises a successful `eval` request, checks the structured runtime-error path, and verifies the malformed-JSON disconnect behavior.

## Manual Smoke Test

Start a server in one terminal:

```bash
julia --project=. -e 'using REPLy; server = REPLy.serve(port=5555); println("REPLy listening on $(REPLy.server_port(server))"); wait(Condition())'
```

Then send a request from another terminal:

```bash
printf '%s\n' '{"op":"eval","id":"demo-1","code":"println(\"hello\"); 1 + 1"}' | nc 127.0.0.1 5555
```

You should receive a done-terminated response stream like:

```json
{"id":"demo-1","out":"hello\n"}
{"id":"demo-1","value":"2","ns":"##REPLySession#..."}
{"id":"demo-1","status":["done"]}
```

The exact field order is not significant, and the generated `ns` value will vary by run.

A runtime error should produce one structured error response with `done` in `status`:

```bash
printf '%s\n' '{"op":"eval","id":"demo-err","code":"missing_name + 1"}' | nc 127.0.0.1 5555
```

Malformed JSON should cause the server to close the connection without emitting a protocol message:

```bash
printf '%s\n' '{"op":"eval","id":}' | nc 127.0.0.1 5555
```

## Getting Started

```julia
using REPLy

protocol_name()   # "REPLy"
version_string()  # "0.1.0"
```
