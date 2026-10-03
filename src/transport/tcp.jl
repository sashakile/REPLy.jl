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

# REQ-RPL-047e (security): record an audit entry for a rejected oversized
# message and close the connection. No response is sent: the message body is
# untrusted, so no request id can be correlated.
function _record_oversize_audit!(state::Union{Nothing, ServerState}, ex::MessageTooLargeError, socket)
    state === nothing && return nothing
    source_ip = try
        socket isa Sockets.TCPSocket ? string(Sockets.getpeername(socket)[1]) : ""
    catch
        ""
    end
    record_audit!(state.audit_log, AuditLogEntry(
        timestamp=now(UTC), client_id=UUID(UInt128(0)), session_id=nothing,
        operation="", user="", source_ip=source_ip, success=false,
        error="message exceeds maximum size of $(ex.limit) bytes"))
    return nothing
end

# BIZ-008 (security): a disconnecting client must not leave evals for its
# requests running indefinitely and producing output to a closed channel.
# Interrupts the in-flight eval tasks whose lifecycle request_id matches the
# connection's in-flight request. v1 approximation: identity is scoped by
# request_id, not by connection — a cross-connection id collision widens the
# cancel to both evals; per-connection audit identity is REPLy_jl-l9tg's scope.
function _cancel_request_evals!(state::Union{Nothing, ServerState}, request_id::AbstractString)
    state === nothing && return nothing
    for life in active_eval_lifecycles(state)
        life.request_id == request_id && request_eval_cancel!(life)
    end
    return nothing
end

function handle_client!(socket::IO, handler::Function;
    max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES,
    rate_limit_per_min::Int=0,
    state::Union{Nothing, ServerState}=nothing,
)
    transport = JSONTransport(socket, ReentrantLock())
    return handle_client!(transport, handler; socket=socket, max_message_bytes=max_message_bytes, rate_limit_per_min=rate_limit_per_min, state=state)
end

# REQ-RPL-002/REQ-RPL-040: the connection loop is transport-agnostic — any
# AbstractTransport implementing the four interface methods (send!, receive,
# close, isopen) drives this loop unchanged.
function handle_client!(transport::AbstractTransport, handler::Function;
    max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES,
    rate_limit_per_min::Int=0,
    state::Union{Nothing, ServerState}=nothing,
    socket::Union{Nothing, IO}=nothing,
)
    # Per-connection rate-limit state: sliding 60-second window.
    # When rate_limit_per_min == 0, enforcement is disabled.
    rl_window_start = time()
    rl_count        = 0
    consecutive_malformed = 0
    # BIZ-008 (security): request id of the eval currently in flight on this
    # connection, cancelled if the connection drops while the eval runs.
    in_flight_request_id = Ref{Union{Nothing, String}}(nothing)

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
                    # REQ-RPL-047e (security): an oversized message closes the
                    # connection with an audit entry and NO response — the body
                    # is untrusted, so no request id can be correlated.
                    _record_oversize_audit!(state, ex, socket)
                    return nothing
                end
                if ex isa MalformedJSONError
                    # REQ-RPL-020 (core-operations): log the parse failure and
                    # count it — no response is sent because no request id can
                    # be trusted for correlation. Connection closes only after
                    # 10 consecutive malformed messages (REQ-RPL-020,
                    # error-handling).
                    @debug "malformed JSON from client" counter = consecutive_malformed + 1
                    consecutive_malformed += 1
                    consecutive_malformed >= 10 && return nothing
                    continue
                end
                rethrow()
            end
            consecutive_malformed = 0
            isnothing(msg) && return nothing

            admitted = isnothing(state) || (socket isa IO ? begin_request!(state, socket) : true)
            admitted || return nothing

            try
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
                in_flight_request_id[] = safe_request_id(msg)

                # BIZ-008 (security): if the client disconnects while an eval
                # that never emits output is in flight, no send failure would
                # ever interrupt it — wait for transport EOF instead. eof()
                # blocks until the client disconnects (the request loop is
                # parked on the stream channel, so no concurrent socket reads).
                disconnect_watcher = @async begin
                    try
                        if socket isa IO
                            while !eof(socket)
                                sleep(0.05)
                            end
                        else
                            while isopen(transport)
                                sleep(0.05)
                            end
                        end
                    catch
                    end
                    rid = in_flight_request_id[]
                    isnothing(rid) || _cancel_request_evals!(state, rid)
                end

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
                        if is_connection_closed(ex)
                            _cancel_request_evals!(state, safe_request_id(msg))
                            return nothing
                        end
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
            finally
                if !isnothing(state)
                    socket isa IO && end_request!(state, socket)
                end
            end

            # Never run close recursively in the request task: it would wait
            # for itself. The response is fully sent and request accounting is
            # released before the asynchronous closer starts.
            if !isnothing(state) && state.shutdown_requested[]
                @async _trigger_shutdown_callback()
                return nothing
            end
            in_flight_request_id[] = nothing
        end
    finally
        if socket isa IO
            isopen(socket) && close(socket)
        else
            isopen(transport) && close(transport)
        end
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

# REQ-RPL-041 (nv69): classify a pre-existing entry at the socket path before
# listen. A live socket is never unlinked or hijacked, a non-socket filesystem
# entry is never deleted — both fail startup with an error naming the path.
# Only a demonstrably stale socket (exists, is a socket inode, nothing
# listening behind it) is cleared so the server can recover from a crashed
# predecessor. `connect` is the liveness probe: it succeeds only when a
# listener accepts, and its client connection is closed immediately.
function _clear_stale_socket_path!(path::AbstractString)
    ispath(path) || return nothing

    issocket(path) || throw(Base.IOError(
        "refusing to remove $(path): not a Unix socket — " *
        "delete it manually or choose a different socket_path", -1))

    live = try
        sock = connect(path)
        close(sock)
        true
    catch
        false
    end
    live && throw(Base.IOError(
        "Unix socket at $(path) is live — refusing to unlink or hijack it; " *
        "choose a different socket_path", -1))

    rm(path; force=true)
    return nothing
end

"""
    listen_unix(path::AbstractString) -> Base.Server

Create an owner-only (0o600) Unix domain socket listener at `path`.

A pre-existing entry at `path` is classified before binding (REQ-RPL-041): a
demonstrably stale socket (socket inode with nothing listening behind it) is
removed so the server recovers from a crashed predecessor; a live socket or a
non-socket filesystem entry is never removed, and a `Base.IOError` naming the
path is thrown instead.
"""
function listen_unix(path::AbstractString)
    _clear_stale_socket_path!(path)

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
