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

function serve(; host::IPAddr=ip"127.0.0.1", port::Integer=5555, socket_path::Union{Nothing, AbstractString}=nothing, manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack())
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
