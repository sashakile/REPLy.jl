server_port(server::TCPServerHandle) = server.port

function wait_for_server_task(task::Task)
    istaskstarted(task) || return nothing
    try
        wait(task)
    catch ex
        is_connection_closed(ex) || rethrow()
    end
    return nothing
end

function serve(; host::IPAddr=ip"127.0.0.1", port::Integer=5555, manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack())
    listener = listen(host, Int(port))
    assigned_port = Int(getsockname(listener)[2])
    handler = build_handler(; manager=manager, middleware=middleware)
    closing = Ref(false)

    server = TCPServerHandle(
        listener,
        assigned_port,
        Task(() -> nothing),
        Task[],
        TCPSocket[],
        handler,
        closing,
    )
    server.accept_task = @async accept_loop!(listener, server)
    return server
end

function Base.close(server::TCPServerHandle)
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
