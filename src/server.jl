server_port(server::TCPServerHandle) = server.port
server_socket_path(server::UnixServerHandle) = server.path

function wait_for_server_task(task::Task)
    istaskstarted(task) || return nothing
    try
        wait(task)
    catch ex
        is_connection_closed(ex) || rethrow()
    end
    return nothing
end

"""
    serve(; host=ip"127.0.0.1", port=5555, socket_path=nothing, manager=SessionManager(), middleware=default_middleware_stack(), max_message_bytes=DEFAULT_MAX_MESSAGE_BYTES)

Start the REPLy JSON-RPC server. If `socket_path` is provided, a Unix domain socket server
is created at that path. Otherwise, a TCP server is started on the given `host` and `port`.

# Arguments
- `host`: The IP address to listen on (default: `127.0.0.1`).
- `port`: The port to listen on (default: `5555`).
- `socket_path`: An optional path for a Unix domain socket server. Mutually exclusive with `host`/`port`.
- `manager`: The `SessionManager` used to track state across sessions.
- `middleware`: A vector of middleware handlers to process incoming requests.
- `max_message_bytes`: Maximum allowed inbound message size in bytes. Requests exceeding this
  limit are rejected with a structured error response and the connection is closed (default: `DEFAULT_MAX_MESSAGE_BYTES`, 1 MiB).

# Returns
A server handle (`TCPServerHandle` or `UnixServerHandle`) which can be closed with `close(server)`.
"""
function serve(; host::IPAddr=ip"127.0.0.1", port::Integer=5555, socket_path::Union{Nothing, AbstractString}=nothing, manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack(), max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES)
    max_message_bytes > 0 || throw(ArgumentError("max_message_bytes must be positive, got $max_message_bytes"))
    handler = build_handler(; manager=manager, middleware=middleware)
    closing = Ref(false)

    if !isnothing(socket_path)
        if host != ip"127.0.0.1" || Int(port) != 5555
            throw(ArgumentError("socket_path is mutually exclusive with host/port TCP arguments"))
        end
        listener = listen_unix(socket_path)
        server = UnixServerHandle(
            listener,
            String(socket_path),
            Task(() -> nothing),
            Task[],
            IO[],
            handler,
            closing,
            max_message_bytes,
        )
        server.accept_task = @async accept_loop!(listener, server)
        return server
    end

    listener = listen(host, Int(port))
    assigned_port = Int(getsockname(listener)[2])
    server = TCPServerHandle(
        listener,
        assigned_port,
        Task(() -> nothing),
        Task[],
        IO[],
        handler,
        closing,
        max_message_bytes,
    )
    server.accept_task = @async accept_loop!(listener, server)
    return server
end

function close_server!(server)
    server.closing[] && return nothing
    server.closing[] = true

    for client in copy(server.clients)
        isopen(client) && close(client)
    end

    isopen(server.listener) && close(server.listener)

    wait_for_server_task(server.accept_task)

    for task in copy(server.client_tasks)
        istaskdone(task) || wait_for_server_task(task)
    end

    return nothing
end

function Base.close(server::TCPServerHandle)
    return close_server!(server)
end

function Base.close(server::UnixServerHandle)
    try
        close_server!(server)
    finally
        ispath(server.path) && rm(server.path; force=true)
    end
    return nothing
end
