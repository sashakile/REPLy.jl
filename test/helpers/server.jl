using Sockets

function with_server(f; port=0)
    server = REPLy.serve(; port=port)
    handle = (; server, port=getfield(server, :port))

    try
        return f(handle)
    finally
        close(server)
    end
end
