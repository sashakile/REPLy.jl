# Connect to an Existing Julia Application

Use `connect_endpoint` to connect to a REPLy listener explicitly enabled inside your Julia application. Install REPLy in both the application and client environments, and keep the application running while clients use its endpoint.

## Enable the Application Endpoint

Run this during application initialization or at an existing Julia prompt:

```julia
using REPLy
endpoint = REPLy.serve(; port=0)
println(REPLy.server_port(endpoint))
```

The application owns this handle and closes it with `close(endpoint)`. Connecting does not load code into an arbitrary process or start a replacement application.

For Unix sockets, choose an unused path:

```julia
endpoint = REPLy.serve(; socket_path="/tmp/my-julia-app.sock")
```

## Connect and Evaluate

In your client process, use the port printed by the application:

```julia
using REPLy
client = connect_endpoint("127.0.0.1", application_port; connect_timeout_s=5)
try
    println(client.capabilities)
    send!(client, Dict("op" => "eval", "id" => "example", "code" => "1 + 1"))
    replies = REPLy.collect_until_done(client, "example")
    println(replies)
finally
    disconnect(client)
end
```

Use `connect_endpoint("/tmp/my-julia-app.sock")` for a Unix endpoint. One timeout budget covers DNS resolution, connection, and the matching `describe` terminal. Discovery requires operation/version objects and JSON encoding support. A valid older endpoint succeeds with unknown execution guarantees in `client.capabilities`.

Existing `Client(host, port)` and `Client(socket_path)` constructors connect without discovery. Use these when preserving that behavior is required.

## Expose Application State Explicitly

Default evaluation sessions use anonymous modules. To expose `Main`, the application creates a trusted session before serving:

```julia
manager = REPLy.SessionManager()
REPLy.create_named_session!(manager, "application"; trusted=true)
endpoint = REPLy.serve(; manager, port=0)
```

The client selects it by including `"session" => "application"` in an eval request. Choose this host configuration only when connected clients should access and mutate application bindings.

## Diagnose Connection Failures

A refused connection means no listener is reachable at the chosen address. A discovery timeout can mean a silent peer or an application whose Julia scheduler is blocked. Malformed replies, a missing matching terminal, or unsupported encoding fail discovery and close the attempted socket.

Attached endpoints report cooperative timeout enforcement and unsupported memory enforcement. Non-yielding Julia or native work can delay their responses. Disconnect closes the client connection and requests cooperative cancellation of its active work; the application retains ownership of its process and listener.

See [Unix socket setup](howto-unix-sockets.md) and [session management](howto-sessions.md) for endpoint and session details.
