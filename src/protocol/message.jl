abstract type AbstractTransport end

struct JSONTransport <: AbstractTransport
    io::IO
    lock::ReentrantLock
end

struct MessageTooLargeError <: Exception
    limit::Int
end

function send!(transport::JSONTransport, msg::Dict)
    lock(transport.lock) do
        write(transport.io, JSON3.write(msg))
        write(transport.io, UInt8('\n'))
        flush(transport.io)
    end
    return nothing
end

const DEFAULT_MAX_MESSAGE_BYTES = 1_048_576  # 1 MiB

"""
    read_bounded_line(io, max_bytes) -> String

Read bytes from `io` up to the next newline (`\\n`), returning the line content
without the trailing newline. Throws `MessageTooLargeError(max_bytes)` if more
than `max_bytes` bytes are read before a newline is found.

Unlike `readline()`, memory use is proportional to `min(actual_bytes, max_bytes)`
rather than the full payload size.
"""
function read_bounded_line(io::IO, max_bytes::Int)
    buf = Vector{UInt8}()
    sizehint!(buf, min(4096, max_bytes))
    count = 0
    while !eof(io)
        b = read(io, UInt8)
        b == UInt8('\n') && return String(buf)
        count += 1
        count > max_bytes && throw(MessageTooLargeError(max_bytes))
        push!(buf, b)
    end
    return String(buf)
end

function receive(transport::JSONTransport; max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES)::Union{Dict{String, Any}, Nothing}
    # REQ-RPL-040b: disconnects/partial reads must not escape to callers.
    # Wrap the entire loop so IOError from eof() (e.g. ECONNRESET) is also caught.
    try
        while !eof(transport.io)
            line = try
                read_bounded_line(transport.io, max_message_bytes)
            catch ex
                ex isa MessageTooLargeError && rethrow()
                return nothing
            end

            isempty(strip(line)) && continue

            msg = try
                JSON3.read(line)
            catch
                # Malformed wire JSON is treated as a closed boundary.
                return nothing
            end

            msg isa JSON3.Object || continue
            return Dict{String, Any}(String(key) => value for (key, value) in pairs(msg))
        end
    catch ex
        ex isa MessageTooLargeError && rethrow()
        return nothing
    end

    return nothing
end

Base.isopen(transport::JSONTransport) = isopen(transport.io)
Base.close(transport::JSONTransport) = close(transport.io)

function response_message(request_id::AbstractString, pairs::Pair...)
    msg = Dict{String, Any}("id" => request_id)
    for (key, value) in pairs
        msg[String(key)] = value
    end
    return msg
end

done_response(request_id::AbstractString) = response_message(request_id, "status" => ["done"])

function error_response(
    request_id::AbstractString,
    err::AbstractString;
    status_flags::Vector{String}=String["error"],
    ex=nothing,
    bt=nothing,
)
    status = unique(vcat(String["done"], status_flags))
    msg = response_message(request_id, "status" => status, "err" => err)

    if !isnothing(ex)
        msg["ex"] = Dict(
            "type" => string(typeof(ex)),
            "message" => exception_message(ex),
        )
        msg["stacktrace"] = stacktrace_payload(something(bt, catch_backtrace()))
    end

    return msg
end

is_kebab_case_key(key::AbstractString) = occursin(r"^[a-z][a-z0-9-]*$", key)

is_flat_value(value) = !(value isa AbstractDict || value isa JSON3.Object)

function validate_request(msg::AbstractDict; max_id_length::Int=256)
    request_id = get(msg, "id", "")
    if !(request_id isa AbstractString)
        return error_response("", "id must be a string")
    end
    if isempty(request_id)
        return error_response("", "id must not be empty")
    end
    if ncodeunits(request_id) > max_id_length
        return error_response(request_id, "id exceeds maximum length of $(max_id_length)")
    end
    if !haskey(msg, "op")
        return error_response(request_id, "op is required")
    end
    if !(msg["op"] isa AbstractString)
        return error_response(request_id, "op must be a string")
    end

    for (key, value) in pairs(msg)
        key_string = String(key)
        if !is_kebab_case_key(key_string)
            return error_response(request_id, "request keys must use kebab-case")
        end
        if !is_flat_value(value)
            return error_response(request_id, "request message must use a flat JSON envelope")
        end
    end

    return nothing
end
