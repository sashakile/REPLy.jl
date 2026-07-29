# REPLy.jl

> **TL;DR** — REPLy.jl is a network REPL server for Julia. Start a server with
> `REPLy.serve(port=5555)`, connect via `nc` or the `replyc` CLI client, and evaluate
> Julia code interactively. Supports TCP and Unix sockets, persistent named sessions,
> and MCP integration.

[![tracked with wai](https://img.shields.io/badge/tracked%20with-wai-blue)](https://github.com/charly-vibes/wai)

> **⚠ AI-Assisted Development.** This project is built through a structured Human–AI
> pair-programming workflow. Substantive changes are tracked in specifications and
> tickets, tested, reviewed with automated tools, and approved by the maintainer.
> The project has **not** had a professional security audit or human line-by-line
> review of the entire codebase.
> [Learn more about the methodology.](docs/src/methodology.md)

**REPLy.jl** is a network REPL server for Julia. It exposes a Julia session over a socket-based protocol (newline-delimited JSON), allowing editors, IDEs, and other tooling to connect, evaluate code, and inspect results interactively — similar to [nREPL](https://nrepl.org/) for Clojure.

## Key Features

- **Robust Execution**: Concurrent evaluation with captured `stdout`/`stderr` and structured error reporting.
- **Persistent Sessions**: Maintain state across requests with named sessions and binding isolation.
- **Rich Introspection**: Built-in support for tab-completion, documentation lookup, and file loading.
- **Flexible Transports**: Supports both TCP and Unix domain sockets (with owner-only permissions).
- **MCP Integration**: Includes a reference adapter for the [Model Context Protocol](https://modelcontextprotocol.io/), exposing Julia as a tool-calling target for LLMs. [See the MCP adapter guide](docs/src/howto-mcp-adapter.md).
- **Revise Hook**: Automatic integration with [Revise.jl](https://github.com/timholy/Revise.jl) to pick up code changes between evaluations.
- **Security & Limits**: Configurable resource limits (message size, output size, timeouts) and audit logging.
- **Graceful Shutdown**: Servers automatically shut down cleanly on `SIGTERM` (`kill`), or via the `shutdown` RPC command.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/sashakile/REPLy.jl")
```

REPLy is not yet registered in Julia's General registry, so installation currently
uses the repository URL.

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

### 4. Use the `replyc` CLI Client

The `nc` examples above corrupt any code containing `"`, `$`, or `\` — that is,
almost all real Julia. For a batteries-included client that encodes JSON
correctly, invoke `REPLy.replyc` from any environment where REPLy is installed:

```bash
# Evaluate code (quotes, $, and backslashes round-trip safely)
julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- eval --port 5555 's = "a\"b\$c\\d"; length(s)'

# Named sessions
julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- session new --port 5555 myapp
julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- eval --port 5555 --session myapp 'x = 41; x + 1'
julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- session ls --port 5555
julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- session rm --port 5555 myapp
```

From a source checkout, `julia --project=. bin/replyc ...` is an equivalent
convenience wrapper.

`replyc` exits non-zero when the server reports an error, so it composes with
shell scripts. Defaults: `--host 127.0.0.1`, `--port 5555`.

### 5. Graceful Shutdown

When running the server as a background process, send `SIGTERM` (`kill`) to
trigger an orderly shutdown that drains clients, interrupts active evaluations,
and cleans up OS resources (Unix domain sockets are removed):

```bash
kill %1  # or pkill -f "julia.*REPLy.serve"
```

To shut down the server from another process, use the `replyc shutdown` command:

```bash
julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- shutdown --port 5555
```

The server responds with `status:["done","shutdown-started"]` and then closes
gracefully. The `replyc` client exits with code 0 after the shutdown signal is
sent.

This is also available via the raw protocol:

```bash
printf '%s\n' '{"op":"shutdown","id":"bye"}' | nc 127.0.0.1 5555
```

## Development and Testing

The current implementation provides a solid TCP server foundation with request validation, structured responses, and concurrent client handling.

### Testing

- `just test` — run the full Julia test suite.
- `just smoke-test` — starts a temporary server, exercises an `eval` request, checks the structured error path, and verifies malformed JSON handling.

### Repository Hygiene

This repository uses `just` for lightweight automation:
- `just bootstrap` — install git hooks with `lefthook`
- `just hooks` — run git-hook checks on all files
- `just lint` — run spelling and prose checks
- `just docs-build` — build the documentation in a reproducible local environment
- `just check` — workflow lint + prose/spelling lint + test + smoke test + coverage
- `just full-check` — `just check` plus OpenSpec and `wai` health checks
