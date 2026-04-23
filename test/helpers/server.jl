using Sockets

function with_server(f; port=0)
    server = REPLy.serve(; port=port)
    handle = (; server, port=REPLy.server_port(server))

    try
        return f(handle)
    finally
        close(server)
    end
end

function with_unix_server(f; path=tempname())
    server = REPLy.serve(; socket_path=path)
    handle = (; server, path=REPLy.server_socket_path(server))

    try
        return f(handle)
    finally
        close(server)
    end
end

function with_multi_server(f; tcp_port=0, unix_path=tempname(), kwargs...)
    server = REPLy.serve_multi((; port=tcp_port), (; socket_path=unix_path); kwargs...)
    tcp_port_assigned = REPLy.server_port(server.listeners[1])
    unix_path_assigned = REPLy.server_socket_path(server.listeners[2])
    handle = (; server, tcp_port=tcp_port_assigned, unix_path=unix_path_assigned)
    try
        return f(handle)
    finally
        close(server)
    end
end
