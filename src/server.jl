server_port(server::TCPServerHandle) = server.port
server_socket_path(server::UnixServerHandle) = server.path

# 127.0.0.0/8 (RFC 5735) and ::1 (RFC 4291) are loopback-only.
_is_loopback(host::Sockets.IPv4) = (host.host >>> 24) == 127
_is_loopback(host::Sockets.IPv6) = host == ip"::1"
_is_loopback(::Any) = false

function _warn_if_non_loopback(host, port)
    _is_loopback(host) && return nothing
    @warn "REPLy TCP server bound to non-loopback address $host:$port — " *
          "no authentication is required to connect. " *
          "Any client that can reach this address can execute arbitrary Julia code in this process. " *
          "Restrict access at the network level (firewall, VPN) or use " *
          "serve(; socket_path=...) for a Unix domain socket with owner-only access."
    return nothing
end

function wait_for_server_task(task::Task)
    istaskstarted(task) || return nothing
    try
        wait(task)
    catch ex
        is_connection_closed(ex) || rethrow()
    end
    return nothing
end

"""
    serve(; host=ip"127.0.0.1", port=5555, socket_path=nothing, manager=SessionManager(), middleware=default_middleware_stack(), limits=ResourceLimits(), max_message_bytes=DEFAULT_MAX_MESSAGE_BYTES)

Start the REPLy JSON-RPC server. If `socket_path` is provided, a Unix domain socket server
is created at that path. Otherwise, a TCP server is started on the given `host` and `port`.

# Arguments
- `host`: The IP address to listen on (default: `127.0.0.1`).
- `port`: The port to listen on (default: `5555`).
- `socket_path`: An optional path for a Unix domain socket server. Mutually exclusive with `host`/`port`.
- `manager`: The `SessionManager` used to track state across sessions.
- `middleware`: A vector of middleware handlers to process incoming requests.
- `limits`: A `ResourceLimits` struct with server-wide resource constraints (default: `ResourceLimits()`).
- `max_message_bytes`: Maximum allowed inbound message size in bytes. Requests exceeding this
  limit are rejected with a structured error response and the connection is closed (default: `DEFAULT_MAX_MESSAGE_BYTES`, 1 MiB).

# Returns
A server handle (`TCPServerHandle` or `UnixServerHandle`) which can be closed with `close(server)`.
"""
function serve(; host::IPAddr=ip"127.0.0.1", port::Integer=5555, socket_path::Union{Nothing, AbstractString}=nothing, manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack(), limits::ResourceLimits=ResourceLimits(), max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES)
    max_message_bytes > 0 || throw(ArgumentError("max_message_bytes must be positive, got $max_message_bytes"))
    closing = Ref(false)
    state = ServerState(limits, max_message_bytes)
    stack = materialize_middleware_stack(middleware)
    handler = build_handler(; manager=manager, middleware=stack, state=state)

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
            ReentrantLock(),
            handler,
            stack,
            closing,
            state,
        )
        server.accept_task = @async accept_loop!(listener, server)
        return server
    end

    listener = listen(host, Int(port))
    assigned_port = Int(getsockname(listener)[2])
    _warn_if_non_loopback(host, assigned_port)
    server = TCPServerHandle(
        listener,
        assigned_port,
        Task(() -> nothing),
        Task[],
        IO[],
        ReentrantLock(),
        handler,
        stack,
        closing,
        state,
    )
    server.accept_task = @async accept_loop!(listener, server)
    return server
end

const DEFAULT_CLOSE_GRACE_SECONDS = 5.0

function interrupt_active_evals!(state::ServerState)
    for task in active_eval_tasks(state)
        istaskdone(task) && continue
        try
            schedule(task, InterruptException(); error=true)
        catch
        end
    end
    return nothing
end

function shutdown_middleware_stack!(middleware::Vector{AbstractMiddleware})
    for mw in reverse(middleware)
        shutdown_middleware!(mw)
    end
    return nothing
end

# Close the network listener and wait for the accept loop to finish.
function _close_listener!(handle::AbstractServerHandle)
    isopen(handle.listener) && close(handle.listener)
    wait_for_server_task(handle.accept_task)
end

# Close all connected clients and wait for their handler tasks to finish.
function _drain_clients!(handle::AbstractServerHandle, deadline::Real)
    for client in lock(handle.clients_lock) do; copy(handle.clients); end
        isopen(client) && close(client)
    end
    for task in lock(handle.clients_lock) do; copy(handle.client_tasks); end
        remaining = deadline - time()
        remaining > 0 && timedwait(() -> istaskdone(task), remaining)
    end
end

# Remove listener-type-specific OS resources after shutdown.
_cleanup_socket!(::TCPServerHandle) = nothing
function _cleanup_socket!(handle::UnixServerHandle)
    ispath(handle.path) && rm(handle.path; force=true)
end

function close_server!(server::AbstractServerHandle; grace_seconds::Real=DEFAULT_CLOSE_GRACE_SECONDS)
    grace_seconds > 0 || throw(ArgumentError("grace_seconds must be positive, got $grace_seconds"))
    server.closing[] && return nothing
    server.closing[] = true

    deadline = time() + Float64(grace_seconds)

    _close_listener!(server)
    interrupt_active_evals!(server.state)

    for task in active_eval_tasks(server.state)
        remaining = deadline - time()
        remaining > 0 && timedwait(() -> istaskdone(task), remaining)
    end

    _drain_clients!(server, deadline)
    shutdown_middleware_stack!(server.middleware)
    return nothing
end

function Base.close(server::TCPServerHandle; kwargs...)
    return close_server!(server; kwargs...)
end

function Base.close(server::UnixServerHandle; kwargs...)
    try
        close_server!(server; kwargs...)
    finally
        _cleanup_socket!(server)
    end
    return nothing
end

"""
    serve_multi(specs...; manager, middleware, limits, max_message_bytes)

Start multiple listeners (TCP and/or Unix domain socket) that share one session
namespace and one resource-limit domain.

Each `spec` is a named tuple with either:
- `(; port=N)` or `(; host=..., port=N)` for a TCP listener
- `(; socket_path="...")` for a Unix domain socket listener

Returns a `MultiListenerServer` which can be closed with `close(server)`.
"""
function serve_multi(specs...; manager::SessionManager=SessionManager(), middleware::Vector{<:AbstractMiddleware}=default_middleware_stack(), limits::ResourceLimits=ResourceLimits(), max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES)
    max_message_bytes > 0 || throw(ArgumentError("max_message_bytes must be positive, got $max_message_bytes"))
    isempty(specs) && throw(ArgumentError("serve_multi requires at least one listener spec"))

    closing = Ref(false)
    state = ServerState(limits, max_message_bytes)
    stack = materialize_middleware_stack(middleware)
    handler = build_handler(; manager=manager, middleware=stack, state=state)

    listeners = AbstractServerHandle[]
    for spec in specs
        if hasproperty(spec, :socket_path)
            listener = listen_unix(spec.socket_path)
            handle = UnixServerHandle(listener, String(spec.socket_path), Task(() -> nothing), Task[], IO[], ReentrantLock(), handler, stack, closing, state)
            handle.accept_task = @async accept_loop!(listener, handle)
            push!(listeners, handle)
        else
            h = hasproperty(spec, :host) ? spec.host : ip"127.0.0.1"
            p = hasproperty(spec, :port) ? spec.port : 0
            listener = listen(h, Int(p))
            assigned_port = Int(getsockname(listener)[2])
            _warn_if_non_loopback(h, assigned_port)
            handle = TCPServerHandle(listener, assigned_port, Task(() -> nothing), Task[], IO[], ReentrantLock(), handler, stack, closing, state)
            handle.accept_task = @async accept_loop!(listener, handle)
            push!(listeners, handle)
        end
    end

    return MultiListenerServer(listeners, closing, state, stack)
end

function Base.close(server::MultiListenerServer; grace_seconds::Real=DEFAULT_CLOSE_GRACE_SECONDS)
    grace_seconds > 0 || throw(ArgumentError("grace_seconds must be positive, got $grace_seconds"))
    server.closing[] && return nothing
    server.closing[] = true

    deadline = time() + Float64(grace_seconds)

    # Batch-close all listeners, then wait for accept tasks — better parallelism
    # than sequential close+wait per listener (which close_server! does for single handles).
    for handle in server.listeners
        isopen(handle.listener) && close(handle.listener)
    end
    for handle in server.listeners
        wait_for_server_task(handle.accept_task)
    end

    interrupt_active_evals!(server.state)

    for task in active_eval_tasks(server.state)
        remaining = deadline - time()
        remaining > 0 && timedwait(() -> istaskdone(task), remaining)
    end

    for handle in server.listeners
        _drain_clients!(handle, deadline)
    end

    shutdown_middleware_stack!(server.middleware)

    for handle in server.listeners
        _cleanup_socket!(handle)
    end

    return nothing
end
