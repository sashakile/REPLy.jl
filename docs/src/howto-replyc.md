# How-to: Use the `replyc` CLI Client

`replyc` is a minimal command-line client for REPLy. It sends `eval`,
`session`, and `shutdown` requests to a running server over TCP and prints
the results.

If you haven't installed `replyc` yet, see [Install the `replyc` CLI Command](howto-cli-install.md)
first. You need a running REPLy server to connect to — see [Quick Start](index.md#quick-start)
or [REPLy as a Global Dev Tool](howto-dev-tool.md).

## Usage

```text
replyc eval    [--host H] [--port N] [--session NAME] 'CODE'
replyc session new [--host H] [--port N] [NAME]
replyc session ls  [--host H] [--port N]
replyc session rm  [--host H] [--port N] NAME
replyc shutdown [--host H] [--port N]
```

Defaults: `--host 127.0.0.1`  `--port 5555`

## Evaluating Code

### Simple expressions

Pass Julia code as a single argument. Output from `println` is printed first,
then any returned value:

```bash
replyc eval '1 + 1'
# → 2

replyc eval 'println("hello"); 3 * 7'
# → hello
# → 21
```

### Runtime errors

Errors print to stderr and `replyc` exits with code 1:

```bash
replyc eval 'missing_name + 1'
# → (stderr) UndefVarError: `missing_name` not defined
echo $?   # → 1
```

### Multi-line code

Newlines inside the quoted string are passed through. Any shell that supports
multi-line quoting (most do) works:

```bash
replyc eval 'function add(a, b)
    a + b
end
add(3, 4)'
# → 7
```

### Connection errors

If the server is not reachable, `replyc` prints a connection error to stderr
and exits with code 1:

```bash
replyc eval --port 9999 '1+1'
# → (stderr) connection failed: IOError: connect: connection refused (ECONNREFUSED)
echo $?   # → 1
```

## Working with Sessions

By default every `eval` runs in a **fresh ephemeral session** — variables do
not carry over between calls. Use named sessions for persistent state.

### Create a session

```bash
replyc session new my-app
# → a1b2c3d4-... (prints the session UUID)
```

The optional `NAME` argument registers a human-readable alias so you do not
need to remember the UUID.

### Evaluate in a session

```bash
replyc eval --session my-app 'x = 42'
replyc eval --session my-app 'x + 10'
# → 52
```

### List sessions

```bash
replyc session ls
# → a1b2c3d4-...	my-app
```

Each line is `UUID\tNAME` (tab-separated). Sessions created without a name
print only the UUID.

### Close a session

```bash
replyc session rm my-app
```

Accepts a name alias or UUID. Exits 0 on success, 1 if the session is not
found.

## Connecting to a Non-Default Server

### Custom host or port

```bash
replyc eval --host 192.168.1.10 --port 9876 '1 + 1'
```

### Unix domain socket

`replyc` speaks TCP only. To reach a Unix socket server, use a TCP-to-Unix
proxy like `socat`:

```bash
socat TCP-LISTEN:5566,reuseaddr,fork UNIX-CONNECT:/tmp/reply.sock &
replyc eval --port 5566 '1 + 1'
```

Or, if you prefer a direct connection, use a generic tool like
`ncat` or the protocol directly:

```bash
printf '{"op":"eval","id":"1","code":"1+1"}\n' | ncat -U /tmp/reply.sock
```

See [Unix Sockets](howto-unix-sockets.md) for more on socket-based servers.

## Shutting Down the Server

Send a graceful shutdown signal to the server. The server drains clients,
interrupts active evaluations, cleans up OS resources (Unix domain sockets are
removed), and stops accepting new connections:

```bash
replyc shutdown
# → Shutdown signal sent.
```

All connections are closed with a 5-second grace period for in-flight
requests. The command exits 0 once the shutdown signal is acknowledged (the
server may still be running its cleanup tasks).

### Custom host or port

```bash
replyc shutdown --port 9876
replyc shutdown --host 192.168.1.10 --port 9876
```

## Composing with Shell Scripts

`replyc` exits 0 on success and non-zero on error, so it composes with shell
conditionals and pipelines:

```bash
# Guard: check that a server is alive
replyc eval '1 + 1' > /dev/null 2>&1 || { echo "REPLy is not running"; exit 1; }

# Capture the result of an eval
result=$(replyc eval 'read("config.toml", String)')
echo "Config length: ${#result} characters"

# Batch eval via loop
for expr in '1+1' '2+2' '3+3'; do
    replyc eval "$expr" || echo "FAILED: $expr"
done
```

## All Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (eval returned, session created, shutdown signal sent) |
| 1 | Runtime error in the eval (or session not found, connection refused, shutdown failed) |
| 2 | Usage error (unknown command, missing argument) |

## Differences from Raw `nc`

The README demonstrates the protocol with `printf … | nc`. That works for
trivial examples but silently corrupts code containing `$`, `"`, or `\` —
which is most real Julia code. `replyc` sends properly JSON-encoded requests,
so any Julia expression round-trips safely.

## Related

- [Install the `replyc` CLI Command](howto-cli-install.md) — Automatic and
  manual installation.
- [Manage Sessions](howto-sessions.md) — Named sessions, cloning, and session
  lifecycle.
- [REPLy as a Global Dev Tool](howto-dev-tool.md) — Server setup for
  interactive development.
- [Protocol Reference](reference-protocol.md) — The underlying wire protocol
  `replyc` uses.
