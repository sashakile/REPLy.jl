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
