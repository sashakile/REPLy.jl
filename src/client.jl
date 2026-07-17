# Client — first-class REPLy connection client.
#
# Wraps a TCP socket + JSONTransport with connect/send/receive/collect/disconnect,
# eliminating the 4× duplication of the wire protocol across replyc, MCP, test
# helpers, and the tutorial.

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
end

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

Close the underlying TCP connection.
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
