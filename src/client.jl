# Purpose: Provide reusable TCP/Unix REPLy connections for tool builders.
# Responsibilities:
# - Reuse JSONTransport for ordinary send/receive and connection ownership.
# - Offer opt-in endpoint discovery under one monotonic connection budget.
# Rationale: REPLy_jl-q8dz.2 adds checked discovery without changing legacy constructors.

"""
    Client(host::String, port::Int)

A connected REPLy client wrapping a TCP socket with a `JSONTransport`.
Provides `send!`, `receive`, `collect_until_done`, and `disconnect`.

Thread-safe: `send!` and `receive` are serialized via the transport's own lock.
"""
struct Client
    transport::JSONTransport
    host::String
    port::Int
    capabilities::Dict{String, Any}
end

_unknown_capabilities() = Dict{String, Any}(
    "execution-mode" => "unknown", "timeout-enforcement" => "unknown",
    "memory-enforcement" => "unknown", "effective-memory-limit-mb" => 0)

Client(transport::JSONTransport, host::String, port::Int) =
    Client(transport, host, port, _unknown_capabilities())

function Client(host::AbstractString, port::Integer)
    sock = connect(host, port)
    transport = JSONTransport(sock, ReentrantLock())
    return Client(transport, String(host), Int(port))
end

"""
    send!(client::Client, msg::AbstractDict)

Serialize `msg` as JSON and write it to the server, followed by a newline.
"""
function send!(client::Client, msg::AbstractDict)
    send!(client.transport, msg)
    return nothing
end

"""
    receive(client::Client; kwargs...) -> Union{JSON3.Object, Nothing}

Receive a single JSON message from the server. Returns `nothing` on clean
disconnect. Passes keyword arguments through to `JSONTransport.receive`.
"""
function receive(client::Client; kwargs...)
    return receive(client.transport; kwargs...)
end

"""
    collect_until_done(client::Client, request_id::AbstractString; timeout_s::Real=5.0) -> Vector{Dict}

Collect all response messages for `request_id` until the terminal `done` status
arrives or `timeout_s` seconds elapse. Messages for other request ids are silently
dropped. Throws on timeout.
"""
function collect_until_done(client::Client, request_id::AbstractString; timeout_s::Real=5.0)
    reader = @async begin
        msgs = Vector{Dict{String, Any}}()
        while true
            raw = receive(client)
            isnothing(raw) && return msgs
            msg_id = get(raw, "id", nothing)
            msg_id isa AbstractString && msg_id != request_id && continue
            msg = Dict{String, Any}(String(k) => v for (k, v) in pairs(raw))
            push!(msgs, msg)
            status = get(msg, "status", nothing)
            if status isa AbstractVector && ("done" in status)
                return msgs
            end
        end
    end

    status = timedwait(() -> istaskdone(reader), Float64(timeout_s))
    if status !== :ok
        close(client.transport)
        error("timed out waiting $(timeout_s)s for done-terminated response stream")
    end

    return fetch(reader)
end

"""
    disconnect(client::Client)

Close the underlying connection; the application retains endpoint ownership.
"""
function disconnect(client::Client)
    close(client.transport)
    return nothing
end

"""
    isopen(client::Client) -> Bool

Check whether the underlying connection is still open.
"""
Base.isopen(client::Client) = isopen(client.transport)

"""
    Client(socket_path::AbstractString)

Connect to a Unix endpoint without mandatory discovery. `host` holds its path
and `port` is zero. Use `connect_endpoint` to validate the peer and capabilities.
"""
function Client(socket_path::AbstractString)
    sock = connect(socket_path)
    return Client(JSONTransport(sock, ReentrantLock()), String(socket_path), 0)
end

function _validate_discovery!(metadata::Dict{String, Any}, raw, request_id::String)
    raw isa AbstractDict || error("describe response must be an object")
    get(raw, "id", nothing) == request_id || error("describe response id does not match")
    status = get(raw, "status", String[])
    status isa AbstractVector && all(x -> x isa AbstractString, status) ||
        error("describe status must be an array of strings")
    any(x -> x in ("error", "interrupted", "timeout"), status) && error("describe failed")
    merge!(metadata, Dict{String, Any}(String(k) => v for (k, v) in pairs(raw)))
    return "done" in status
end

function _discovery_choice(metadata, key, valid, default)
    value = get(metadata, key, default)
    value == default && return default
    value isa AbstractString && value in valid || error("invalid describe capability: $key")
    return String(value)
end

function _discovery_memory_limit(metadata)
    limit = get(metadata, "effective-memory-limit-mb", 0)
    limit isa Integer && !(limit isa Bool) && limit >= 0 || error("invalid effective memory limit")
    return limit
end

function _discovery_runtime_fields!(capabilities, metadata)
    for key in ("runtime-id", "runtime-state", "orphan-cleanup", "process-tree-cleanup")
        if haskey(metadata, key)
            metadata[key] isa AbstractString || error("invalid describe capability: $key")
            capabilities[key] = String(metadata[key])
        end
    end
    return capabilities
end

function _discovery_capabilities(metadata)
    get(metadata, "ops", nothing) isa AbstractDict || error("describe requires ops")
    get(metadata, "versions", nothing) isa AbstractDict || error("describe requires versions")
    encodings = get(metadata, "encodings-available", nothing)
    encodings isa AbstractVector && "json" in encodings || error("describe requires JSON support")
    get(metadata, "encoding-current", nothing) == "json" || error("describe requires JSON encoding")
    capabilities = Dict{String, Any}(
        "execution-mode" => _discovery_choice(metadata, "execution-mode", ("attached", "managed"), "unknown"),
        "timeout-enforcement" => _discovery_choice(metadata, "timeout-enforcement", ("cooperative", "supervised"), "unknown"),
        "memory-enforcement" => _discovery_choice(metadata, "memory-enforcement", ("unsupported", "os"), "unknown"),
        "effective-memory-limit-mb" => _discovery_memory_limit(metadata))
    return _discovery_runtime_fields!(capabilities, metadata)
end

function _discover_peer(client, expired)
    request_id = string(uuid4())
    send!(client, Dict("op" => "describe", "id" => request_id))
    metadata = Dict{String, Any}()
    while true
        raw = receive(client)
        raw === nothing && error("endpoint closed before describe terminal")
        if _validate_discovery!(metadata, raw, request_id)
            merge!(client.capabilities, _discovery_capabilities(metadata))
            expired() && error("describe completed after connection budget")
            return client
        end
    end
end

# A resolver may finish after the caller's deadline. The expired flag prevents
# that late result from opening a connection; closing the allocated socket wakes
# any active connect/read/write. No task is interrupted while holding an IO lock.
function _checked_endpoint(socket, establish!, endpoint, timeout_s)
    budget = Float64(timeout_s)
    isfinite(budget) && budget > 0 || throw(ArgumentError("connect_timeout_s must be positive and finite"))
    started = time_ns()
    expired = Ref(false)
    client = Client(JSONTransport(socket, ReentrantLock()), String(endpoint[1]), Int(endpoint[2]))
    elapsed() = (time_ns() - started) / 1e9
    isexpired() = expired[] || elapsed() >= budget
    attempt = @async try
        establish!(socket, isexpired)
        isexpired() && error("endpoint discovery timed out")
        _discover_peer(client, isexpired)
    catch
        disconnect(client)
        rethrow()
    end
    expire!() = (expired[] = true; disconnect(client))
    return _await_discovery(attempt, expire!, max(0.0, budget - elapsed()), budget)
end

function _await_discovery(attempt, expire!, remaining, budget)
    result = timedwait(() -> istaskdone(attempt), remaining; pollint=0.001)
    if result !== :ok
        expire!()
        error("endpoint discovery timed out after $(budget)s")
    end
    return fetch(attempt)
end

# Match the existing TCP constructor's name resolution policy.
_resolve_client_host(host) = [Sockets.getaddrinfo(host)]

function _connect_tcp_endpoint(host, port; connect_timeout_s=5, resolver=_resolve_client_host)
    socket = TCPSocket()
    try
        return _checked_endpoint(socket, (sock, expired) -> begin
            addresses = resolver(host)
            expired() && error("endpoint resolution exceeded connection budget")
            isempty(addresses) && error("endpoint name has no addresses")
            # Use the resolved address directly so DNS is never repeated outside
            # the shared budget. Additional address attempts can be requested
            # explicitly by connecting to an address literal.
            connect(sock, first(addresses), port)
        end, (host, port), connect_timeout_s)
    catch
        close(socket)
        rethrow()
    end
end

"""
    connect_endpoint(host, port; connect_timeout_s=5) -> Client
    connect_endpoint(socket_path; connect_timeout_s=5) -> Client

Connect to an explicitly prepared application endpoint and validate its ordinary
`describe` response under one budget covering DNS, connection and discovery.
Failure closes the attempted connection. `client.capabilities` reports discovered
execution guarantees; a valid legacy endpoint reports `"unknown"`. Existing
`Client` constructors perform no discovery. Default sessions remain anonymous
modules; access to application `Main` requires explicit host configuration.
"""
connect_endpoint(host::AbstractString, port::Integer; connect_timeout_s::Real=5) =
    _connect_tcp_endpoint(host, port; connect_timeout_s)

function connect_endpoint(socket_path::AbstractString; connect_timeout_s::Real=5)
    socket = Sockets.PipeEndpoint()
    try
        return _checked_endpoint(socket, (_, _) -> connect(socket, socket_path),
            (socket_path, 0), connect_timeout_s)
    catch
        close(socket)
        rethrow()
    end
end
