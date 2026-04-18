# REPLy.jl
[![tracked with wai](https://img.shields.io/badge/tracked%20with-wai-blue)](https://github.com/charly-vibes/wai)

> **WARNING: This project is entirely LLM-generated code. It has not been manually reviewed or audited. Use at your own risk.**

A network REPL server for Julia — think [nREPL](https://nrepl.org/) for Clojure, but for Julia. REPLy.jl exposes a Julia REPL over a socket-based protocol so that editors and tooling can connect, evaluate code, and inspect results interactively.

## current status

The current tracer-bullet implementation is working end to end.

Implemented today:

- TCP server via `REPLy.serve`
- newline-delimited JSON transport
- request validation for flat, kebab-case envelopes
- `eval` requests with buffered `stdout` and `stderr`
- structured error responses
- one `done` terminator per request
- concurrent client handling
- malformed JSON treated as a closed connection boundary

Not implemented yet:

- a richer operation set beyond `eval`
- persistent named sessions and editor-facing integration layers

## testing

### automated test suite

```bash
just test
```

Current status: the full suite passes locally.

### smoke test script

```bash
just smoke-test
```

This starts a temporary server, verifies a successful `eval`, verifies a structured runtime error response, and confirms malformed JSON closes the connection without a protocol response.

### manual smoke test

Start a server in one terminal:

```bash
julia --project=. -e 'using REPLy; server = REPLy.serve(port=5555); println("REPLy listening on $(REPLy.server_port(server))"); wait(Condition())'
```

Then, from another terminal, send an `eval` request over TCP:

```bash
printf '%s\n' '{"op":"eval","id":"demo-1","code":"println(\"hello\"); 1 + 1"}' | nc 127.0.0.1 5555
```

Expected response shape:

```json
{"id":"demo-1","out":"hello\n"}
{"id":"demo-1","value":"2","ns":"##REPLySession#..."}
{"id":"demo-1","status":["done"]}
```

The exact field order is not significant, and the generated `ns` value will vary by run.

You can also verify error handling:

```bash
printf '%s\n' '{"op":"eval","id":"demo-err","code":"missing_name + 1"}' | nc 127.0.0.1 5555
```

That should return a single error message containing `status`, `err`, `ex`, and `stacktrace`, with `done` included in `status`.

To test the malformed-JSON boundary behavior, send invalid JSON and confirm the server closes the connection without a protocol response:

```bash
printf '%s\n' '{"op":"eval","id":}' | nc 127.0.0.1 5555
```

## repo hygiene

This repository is configured with lightweight automation for local and CI checks.

### Common commands

- `just bootstrap` — install git hooks with `prek` (including a pre-push test gate)
- `just hooks` — run git-hook checks on all files
- `just lint` — run spelling and prose checks
- `just test` — run Julia tests when package files exist
- `just smoke-test` — run a local end-to-end TCP smoke test against a temporary server
- `just coverage` — run Julia coverage when package files exist
- `just check` — lint + test + smoke test + coverage
- `just full-check` — `just check` plus OpenSpec and `wai` health checks

### Tooling added

- `justfile` for common commands
- `prek.toml` for git hook management, including running `just test` on `pre-push`
- `.editorconfig` for formatting conventions
- `_typos.toml` for spelling checks
- `.vale.ini` for prose linting
- `llm.txt` for AI-oriented repo context
- `.github/workflows/ci.yml` for CI
- `.devcontainer/devcontainer.json` for a reproducible dev environment
