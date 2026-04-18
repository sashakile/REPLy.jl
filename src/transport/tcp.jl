mutable struct TCPServerHandle
    listener::Sockets.TCPServer
    port::Int
    accept_task::Task
    client_tasks::Vector{Task}
    clients::Vector{TCPSocket}
    handler::Function
    closing::Base.RefValue{Bool}
end

is_connection_closed(ex) = ex isa Base.IOError || ex isa InvalidStateException

function handle_client!(socket::TCPSocket, handler::Function)
    transport = JSONTransport(socket, ReentrantLock())

    try
        while isopen(transport)
            msg = receive(transport)
            isnothing(msg) && return nothing

            for response in handler(msg)
                try
                    send!(transport, response)
                catch ex
                    is_connection_closed(ex) && return nothing
                    rethrow()
                end
            end
        end
    finally
        isopen(socket) && close(socket)
    end

    return nothing
end

function accept_loop!(listener::Sockets.TCPServer, handle::TCPServerHandle)
    while !handle.closing[]
        socket = try
            accept(listener)
        catch ex
            if handle.closing[] || is_connection_closed(ex)
                return nothing
            end
            rethrow()
        end

        push!(handle.clients, socket)
        task = @async begin
            try
                handle_client!(socket, handle.handler)
            finally
                filter!(client -> client !== socket, handle.clients)
                filter!(existing -> existing !== current_task(), handle.client_tasks)
            end
        end
        push!(handle.client_tasks, task)
    end

    return nothing
end
