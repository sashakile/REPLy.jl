# Tutorial: Building a Custom Client

This tutorial demonstrates how to build a basic custom client in Julia that connects to a REPLy server. REPLy's wire format is simple: requests are JSON objects, and responses are streams of JSON objects terminated by a `status: ["done"]` flag.

## Prerequisites

Start a REPLy server in a separate terminal:

```bash
julia --project=. -e 'using REPLy; REPLy.serve(port=5555); wait(Condition())'
```

## The Client Code

Create a new script `client.jl`. We will use Julia's `Sockets` and `JSON3` standard libraries.

```julia
using Sockets
using JSON3

function evaluate_code(host::IPAddr, port::Int, code::String)
    # 1. Connect to the REPLy server
    conn = connect(host, port)
    
    # 2. Formulate the request
    request_id = "req-$(round(Int, time() * 1000))"
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
        isempty(line) && continue
        
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

## Adding Concurrency (Optional)

Since REPLy servers can handle concurrent clients, you could start multiple asynchronous tasks running `evaluate_code` against the same server.

For advanced editors, a persistent client connection is usually maintained. You would keep the `conn` open and dispatch incoming `id`s to awaiting tasks. Look at REPLy's `mcp_adapter.jl` (specifically `collect_reply_stream`) for an example of handling asynchronous request IDs over a single socket!
