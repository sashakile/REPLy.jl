# How-to: Connect via Unix Domain Sockets

While REPLy defaults to a TCP server, you can also run it over Unix domain sockets. This is highly recommended for local editor integrations because it:
1. Avoids port conflicts.
2. Provides a file-based security boundary (only users with read/write access to the socket file can connect).

## Starting a Unix Socket Server

Instead of passing `host` and `port` to `REPLy.serve`, use the `socket_path` argument:

```julia
using REPLy

# The socket file will be created automatically.
# Any existing file at this path will be overwritten.
socket_path = "/tmp/reply.sock"

server = REPLy.serve(socket_path=socket_path)
println("REPLy listening on $socket_path")

wait(Condition())
```

> **Note:** The server applies restrictive permissions (`0o600`) to the socket file so that only the user who started the server can interact with it.

## Connecting from the Terminal

You can interact with the Unix socket using `netcat` (with the `-U` flag) or `socat`:

```bash
printf '%s\n' '{"op":"eval","id":"demo-1","code":"1 + 1"}' | nc -U /tmp/reply.sock
```

The expected response is identical to the TCP transport:

```json
{"id":"demo-1","value":"2","ns":"##REPLySession#..."}
{"id":"demo-1","status":["done"]}
```

## Cleaning Up

When you call `close(server)` from Julia, the socket file is automatically deleted:

```julia
close(server)
# /tmp/reply.sock is now gone
```
