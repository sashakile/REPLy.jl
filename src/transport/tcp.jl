mutable struct TCPServerHandle
    listener::Sockets.TCPServer
    port::Int
    accept_task::Task
    client_tasks::Vector{Task}
    clients::Vector{IO}
    handler::Function
    middleware::Vector{AbstractMiddleware}
    closing::Base.RefValue{Bool}
    state::ServerState
end

mutable struct UnixServerHandle
    listener::Sockets.PipeServer
    path::String
    accept_task::Task
    client_tasks::Vector{Task}
    clients::Vector{IO}
    handler::Function
    middleware::Vector{AbstractMiddleware}
    closing::Base.RefValue{Bool}
    state::ServerState
end

mutable struct MultiListenerServer
    listeners::Vector{Union{TCPServerHandle, UnixServerHandle}}
    closing::Base.RefValue{Bool}
    state::ServerState
    middleware::Vector{AbstractMiddleware}
end

is_connection_closed(ex) = ex isa Base.IOError || ex isa InvalidStateException

safe_request_id(msg) = get(msg, "id", "") isa AbstractString ? String(get(msg, "id", "")) : ""

function handle_client!(socket::IO, handler::Function;
    max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES,
    rate_limit_per_min::Int=0,
)
    transport = JSONTransport(socket, ReentrantLock())

    # Per-connection rate-limit state: sliding 60-second window.
    # When rate_limit_per_min == 0, enforcement is disabled.
    rl_window_start = time()
    rl_count        = 0

    try
        while isopen(transport)
            msg = try
                receive(transport; max_message_bytes=max_message_bytes)
            catch ex
                if ex isa MessageTooLargeError
                    try
                        send!(transport, error_response("", "message exceeds maximum size of $(ex.limit) bytes"))
                    catch
                    end
                    return nothing
                end
                rethrow()
            end
            isnothing(msg) && return nothing

            # Rate limiting: reset window when 60 s have elapsed.
            if rate_limit_per_min > 0
                now = time()
                if now - rl_window_start >= 60.0
                    rl_window_start = now
                    rl_count        = 0
                end
                rl_count += 1
                if rl_count > rate_limit_per_min
                    request_id = safe_request_id(msg)
                    try
                        send!(transport, error_response(request_id, "Rate limit exceeded";
                            status_flags=String["error", "rate-limited"]))
                    catch
                    end
                    continue
                end
            end

            responses = try
                handler(msg)
            catch ex
                [internal_error_response(safe_request_id(msg), ex; bt=catch_backtrace())]
            end

            for response in responses
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

function accept_loop!(listener, handle)
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
                handle_client!(socket, handle.handler;
                    max_message_bytes  = handle.state.max_message_bytes,
                    rate_limit_per_min = handle.state.limits.rate_limit_per_min,
                )
            finally
                filter!(client -> client !== socket, handle.clients)
                filter!(existing -> existing !== current_task(), handle.client_tasks)
            end
        end
        push!(handle.client_tasks, task)
    end

    return nothing
end

function listen_unix(path::AbstractString)
    ispath(path) && rm(path; force=true)

    # Create the socket with a restrictive umask, then re-assert 0o600 explicitly.
    old_umask = ccall(:umask, Cuint, (Cuint,), 0o077)
    listener = try
        listen(path)
    finally
        ccall(:umask, Cuint, (Cuint,), old_umask)
    end

    try
        chmod(path, 0o600)
        return listener
    catch
        isopen(listener) && close(listener)
        ispath(path) && rm(path; force=true)
        rethrow()
    end
end
