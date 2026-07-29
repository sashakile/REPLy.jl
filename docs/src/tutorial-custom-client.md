# Tutorial: Building a Custom Client

> **TL;DR** — Copy the `client.jl` code below into your project for a working
> REPLy client in Julia. It connects over TCP, sends `eval` requests, and streams
> responses. For persistent sessions, keep one connection open and use named sessions.

This tutorial gives you a copy-paste client recipe in Julia. REPLy has no published client package — the intended workflow is to copy this file into your project and adapt it as needed.

!!! tip "Getting started fast"
    Jump to [The Client Code](#the-client-code) and copy `client.jl` into your project. The rest of the tutorial explains how it works.

For the full request/response contract, see the [Protocol Reference](reference-protocol.md).

## Prerequisites

Start a REPLy server in a separate terminal:

```bash
julia --project=. -e 'using REPLy; REPLy.serve(port=5555); wait(Condition())'
```

## The Client Code

Create a new script `client.jl`. We will use Julia's `Sockets` standard library and the
[`JSON3`](https://github.com/quinnj/JSON3.jl) package. If you haven't installed it yet:

```julia
using Pkg; Pkg.add("JSON3")
```

```julia
using Sockets
using JSON3

function evaluate_code(host::IPAddr, port::Int, code::String)
    # 1. Connect to the REPLy server
    conn = connect(host, port)

    # 2. Formulate the request
    request_id = "req-$(time_ns())"
    request = Dict(
        "op" => "eval",
        "id" => request_id,
        "code" => code
    )

    # 3. Send the request (must be newline-delimited)
    JSON3.write(conn, request)
    write(conn, '\n')
    flush(conn)

    # 4. Read the streaming response
    println("Evaluating: $code\n---")
    while isopen(conn)
        line = readline(conn)
        if isempty(line)
            eof(conn) && break
            continue
        end

        response = JSON3.read(line)

        # Verify this response belongs to our request
        get(response, "id", "") == request_id || continue

        # Handle different response fields
        if haskey(response, "out")
            print(response["out"])
        elseif haskey(response, "err")
            printstyled(response["err"], color=:red)
        elseif haskey(response, "value")
            println("Result: ", response["value"])
        end

        # Check for the terminal "done" flag
        # (Note: `status` is parsed as a JSON3 array, which we can search with `in`)
        status = get(response, "status", String[])
        if "done" in status
            if "error" in status
                println("Evaluation failed with a runtime error.")
            end
            break
        end
    end

    # 5. Cleanup
    close(conn)
end

# Usage:
evaluate_code(ip"127.0.0.1", 5555, "println(\"Hello from client!\"); 1 + 1")
```

## Running the Client

Execute your client script. You should see standard output and the final evaluated result streamed back to you.

```bash
julia client.jl
```

**Output:**
```
Evaluating: println("Hello from client!"); 1 + 1
---
Hello from client!
Result: 2
```

## Persistent Sessions (Keeping State Between Evals)

The recipe above opens a fresh connection per call and runs each eval in a *fresh,
ephemeral* session — variables do **not** survive between calls. For editor integration you
usually want the opposite: one long-lived connection and a **named session** so state
persists. That is what [index.md](index.md#Next-Steps) pointed you here for.

Two changes make it persistent:

1. Keep a single `conn` open and reuse it across evals (don't `close` after each one).
2. Create a named session once, then include `"session" => name` in every request.

```julia
using Sockets
using JSON3

# Send one request over an already-open connection and return the collected responses.
function send_request(conn, request)
    JSON3.write(conn, request)
    write(conn, '\n')
    flush(conn)
    responses = Dict{String,Any}[]
    while isopen(conn)
        line = readline(conn)
        if isempty(line)
            eof(conn) && break
            continue
        end
        msg = JSON3.read(line, Dict{String,Any})
        get(msg, "id", "") == request["id"] || continue   # demux by id
        push!(responses, msg)
        "done" in get(msg, "status", String[]) && break
    end
    return responses
end

# Open ONE connection, create a session, and run several evals against it.
function session_demo(host::IPAddr, port::Int)
    conn = connect(host, port)
    try
        # 1. Create a named session (state will persist in it).
        #    `if-exists => "reuse"` makes this idempotent: re-running the demo against
        #    a server that already has "main" reuses it instead of erroring.
        send_request(conn, Dict("op" => "new-session", "id" => "s-1",
                                "name" => "main", "if-exists" => "reuse"))

        # 2. First eval: define x in the session.
        send_request(conn, Dict("op" => "eval", "id" => "e-1",
                                "session" => "main", "code" => "x = 42"))

        # 3. Second eval on the SAME connection/session: x is still defined.
        rs = send_request(conn, Dict("op" => "eval", "id" => "e-2",
                                     "session" => "main", "code" => "x + 10"))
        for msg in rs
            haskey(msg, "value") && println("Result: ", msg["value"])
        end
    finally
        close(conn)
    end
end

session_demo(ip"127.0.0.1", 5555)
```

**Output:**
```
Result: 52
```

The second eval sees `x` because both ran in the `"main"` session over one connection. See
[How-to: Manage Sessions](howto-sessions.md) for listing, cloning, and closing sessions.

## Adding Concurrency (Optional)

Since REPLy servers can handle concurrent clients, you could start multiple asynchronous tasks running `evaluate_code` against the same server.

For advanced editors, a persistent client connection is usually maintained. You would keep the `conn` open and dispatch incoming `id`s to awaiting tasks. Look at REPLy's `mcp_adapter.jl` (specifically `collect_reply_stream`) for an example of handling asynchronous request IDs over a single socket.

## See Also

- [Protocol Reference](reference-protocol.md) — full request/response contract with error examples
- [How-to: Manage Sessions](howto-sessions.md) — create named sessions for persistent state
