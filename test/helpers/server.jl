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
