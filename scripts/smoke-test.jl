using JSON3
using REPLy
using Sockets

function send_request(sock::TCPSocket, msg::AbstractDict)
    write(sock, JSON3.write(msg))
    write(sock, UInt8('\n'))
    flush(sock)
    return nothing
end

function collect_until_done(sock::TCPSocket; timeout_s::Real=5.0)
    reader = @async begin
        messages = Dict{String, Any}[]

        while isopen(sock)
            local line
            try
                line = readline(sock; keep=true)
            catch ex
                if ex isa EOFError
                    return messages
                end
                rethrow()
            end

            isempty(strip(line)) && continue
            push!(messages, JSON3.read(line, Dict{String, Any}))

            if haskey(messages[end], "status") && ("done" in messages[end]["status"])
                return messages
            end
        end

        return messages
    end

    status = timedwait(() -> istaskdone(reader), timeout_s)
    status === :ok || error("timed out waiting for done-terminated response stream")
    return fetch(reader)
end

function assert_success_path(port::Integer)
    sock = connect(ip"127.0.0.1", port)

    try
        send_request(sock, Dict(
            "op" => "eval",
            "id" => "smoke-success",
            "code" => "println(\"hello\"); 1 + 1",
        ))

        messages = collect_until_done(sock)
        !isempty(messages) || error("expected at least one response message")
        all(get(msg, "id", nothing) == "smoke-success" for msg in messages) ||
            error("all response ids must echo the request id")
        any(get(msg, "out", nothing) == "hello\n" for msg in messages) ||
            error("expected buffered stdout response")
        any(get(msg, "value", nothing) == "2" for msg in messages) ||
            error("expected value response of 2")
        get(last(messages), "id", nothing) == "smoke-success" ||
            error("expected final response to echo the request id")
        get(last(messages), "status", nothing) == Any["done"] ||
            error("expected final done response")
    finally
        close(sock)
    end

    return nothing
end

function assert_error_path(port::Integer)
    sock = connect(ip"127.0.0.1", port)

    try
        send_request(sock, Dict(
            "op" => "eval",
            "id" => "smoke-error",
            "code" => "missing_name + 1",
        ))

        messages = collect_until_done(sock)
        length(messages) == 1 || error("expected a single structured error response")
        message = only(messages)
        all(flag in get(message, "status", String[]) for flag in ["done", "error"]) ||
            error("expected done+error status flags")
        occursin("UndefVarError", get(message, "err", "")) ||
            error("expected UndefVarError in err payload")
        get(get(message, "ex", Dict{String, Any}()), "type", nothing) == "UndefVarError" ||
            error("expected structured exception type")
        get(message, "stacktrace", nothing) isa Vector ||
            error("expected stacktrace vector")
    finally
        close(sock)
    end

    return nothing
end

function assert_malformed_json_boundary(port::Integer)
    sock = connect(ip"127.0.0.1", port)

    try
        write(sock, "{\"op\":\"eval\",\"id\":}\n")
        flush(sock)
        response = read(sock, String)
        isempty(response) || error("expected malformed JSON to close connection without a protocol response")
    finally
        isopen(sock) && close(sock)
    end

    return nothing
end

function main()
    server = REPLy.serve(port=0)

    try
        port = REPLy.server_port(server)
        println("smoke: server listening on 127.0.0.1:$port")

        assert_success_path(port)
        println("smoke: success path ok")

        assert_error_path(port)
        println("smoke: error path ok")

        assert_malformed_json_boundary(port)
        println("smoke: malformed-json boundary ok")

        println("smoke: passed")
    finally
        close(server)
    end

    return nothing
end

main()
