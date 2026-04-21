# REPLy.jl
[![tracked with wai](https://img.shields.io/badge/tracked%20with-wai-blue)](https://github.com/charly-vibes/wai)

> **WARNING: This project is entirely LLM-generated code. It has not been manually reviewed or audited. Use at your own risk.**

**REPLy.jl** is a network REPL server for Julia. It exposes a Julia session over a socket-based protocol (newline-delimited JSON), allowing editors, IDEs, and other tooling to connect, evaluate code, and inspect results interactively — similar to [nREPL](https://nrepl.org/) for Clojure.

## Installation

```julia
using Pkg
Pkg.add("REPLy")
```

## Quick Start

### 1. Start the Server

Start a REPLy server on a local port (default is `5555`):

```bash
julia --project=. -e 'using REPLy; server = REPLy.serve(port=5555); println("REPLy listening on $(REPLy.server_port(server))"); wait(Condition())'
```

### 2. Connect and Evaluate Code

Clients communicate with REPLy by sending newline-delimited JSON messages over TCP. You can test this using `nc` (netcat):

```bash
printf '%s\n' '{"op":"eval","id":"demo-1","code":"println(\"hello\"); 1 + 1"}' | nc 127.0.0.1 5555
```

Expected response shape (forwards stdout, evaluation result, and a `done` terminator):

```json
{"id":"demo-1","out":"hello\n"}
{"id":"demo-1","value":"2","ns":"##REPLySession#..."}
{"id":"demo-1","status":["done"]}
```

### 3. Error Handling

A runtime error will produce a structured error response with `done` in `status`:

```bash
printf '%s\n' '{"op":"eval","id":"demo-err","code":"missing_name + 1"}' | nc 127.0.0.1 5555
```

## Development and Testing

The current implementation provides a solid TCP server foundation with request validation, structured responses, and concurrent client handling.

### Testing

- `just test` — run the full Julia test suite.
- `just smoke-test` — starts a temporary server, exercises an `eval` request, checks the structured error path, and verifies malformed JSON handling.

### Repo Hygiene

This repository uses `just` for lightweight automation:
- `just bootstrap` — install git hooks with `prek`
- `just hooks` — run git-hook checks on all files
- `just lint` — run spelling and prose checks
- `just check` — lint + test + smoke test + coverage
- `just full-check` — `just check` plus OpenSpec and `wai` health checks

