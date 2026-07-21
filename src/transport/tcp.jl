"""
    AbstractServerHandle

Abstract supertype for single-listener server handles. Subtypes (`TCPServerHandle`,
`UnixServerHandle`) must have fields: `listener`, `accept_task`, `client_tasks`,
`clients`, `clients_lock`, `handler`, `middleware`, `closing`, `state`.
"""
abstract type AbstractServerHandle end

mutable struct TCPServerHandle <: AbstractServerHandle
    listener::Sockets.TCPServer
    port::Int
    accept_task::Task
    client_tasks::Vector{Task}
    clients::Vector{IO}
    clients_lock::ReentrantLock
    handler::Function
    middleware::Vector{AbstractMiddleware}
    closing::Base.RefValue{Bool}
    state::ServerState
end

mutable struct UnixServerHandle <: AbstractServerHandle
    listener::Sockets.PipeServer
    path::String
    accept_task::Task
    client_tasks::Vector{Task}
    clients::Vector{IO}
    clients_lock::ReentrantLock
    handler::Function
    middleware::Vector{AbstractMiddleware}
    closing::Base.RefValue{Bool}
    state::ServerState
end

mutable struct MultiListenerServer
    listeners::Vector{AbstractServerHandle}
    closing::Base.RefValue{Bool}
    state::ServerState
    middleware::Vector{AbstractMiddleware}
end

is_connection_closed(ex) = ex isa Base.IOError || ex isa InvalidStateException

safe_request_id(msg) = get(msg, "id", "") isa AbstractString ? String(get(msg, "id", "")) : ""

function handle_client!(socket::IO, handler::Function;
    max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES,
    rate_limit_per_min::Int=0,
    state::Union{Nothing, ServerState}=nothing,
)
    transport = JSONTransport(socket, ReentrantLock())

    # Per-connection rate-limit state: sliding 60-second window.
    # When rate_limit_per_min == 0, enforcement is disabled.
    rl_window_start = time()
    rl_count        = 0
    consecutive_malformed = 0

    try
        while isopen(transport)
            # Check if shutdown was requested (from ShutdownMiddleware)
            if !isnothing(state) && state.shutdown_requested[]
                _trigger_shutdown_callback()
                return nothing
            end

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
                if ex isa MalformedJSONError
                    consecutive_malformed += 1
                    if consecutive_malformed >= 10
                        try
                            send!(transport, error_response("", "too many consecutive malformed requests"))
                        catch
                        end
                        return nothing
                    end
                    try
                        send!(transport, error_response("", "malformed JSON"; status_flags=String["error", "malformed-request"]))
                    catch
                        return nothing
                    end
                    continue
                end
                rethrow()
            end
            consecutive_malformed = 0
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

            # Create a streaming channel for this request so eval can emit
            # interim "out" messages during long-running evals.
            stream = Channel{Dict{String, Any}}(32)

            # Spawn a handler task that uses the stream channel.
            handler_task = @async begin
                try
                    responses = handler(msg, stream)
                    for response in responses
                        put!(stream, response)
                    end
                finally
                    close(stream)
                end
            end

            # Read from the stream channel and send each message as it arrives.
            # This allows the client to see partial stdout during long evals.
            for response in stream
                try
                    send!(transport, response)
                catch ex
                    is_connection_closed(ex) && return nothing
                    rethrow()
                end
            end

            # Wait for the handler task to finish and handle any errors.
            try
                fetch(handler_task)
            catch ex
                if is_connection_closed(ex)
                    return nothing
                end
                # Handler threw — return error response, then continue.
                actual_ex = ex isa TaskFailedException ? ex.task.exception : ex
                request_id = safe_request_id(msg)
                error_resp = internal_error_response(
                    request_id,
                    actual_ex;
                    bt=(ex isa TaskFailedException ? ex.task.backtrace : catch_backtrace()),
                )
                try
                    send!(transport, error_resp)
                catch
                    return nothing
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

        # Enforce connection limit: accept then immediately close if at capacity.
        # Accepting before closing clears the OS backlog entry; closing before
        # spawning a task keeps our own accounting accurate.
        at_limit = lock(handle.clients_lock) do
            if length(handle.clients) >= handle.state.limits.max_connections
                return true
            end
            push!(handle.clients, socket)
            return false
        end
        if at_limit
            close(socket)
            continue
        end

        task = @async begin
            try
                handle_client!(socket, handle.handler;
                    max_message_bytes  = handle.state.max_message_bytes,
                    rate_limit_per_min = handle.state.limits.rate_limit_per_min,
                    state              = handle.state,
                )
            finally
                lock(handle.clients_lock) do
                    filter!(client -> client !== socket, handle.clients)
                    filter!(existing -> existing !== current_task(), handle.client_tasks)
                end
            end
        end
        lock(handle.clients_lock) do
            push!(handle.client_tasks, task)
        end
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
