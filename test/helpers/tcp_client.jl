using JSON3

function send_request(sock, msg::Dict)
    write(sock, JSON3.write(msg))
    write(sock, UInt8('\n'))
    flush(sock)
    return nothing
end

function collect_until_done(sock; timeout_s=5.0)::Vector{Dict}
    reader = @async begin
        msgs = Dict[]

        while isopen(sock)
            local line
            try
                line = readline(sock; keep=true)
            catch ex
                if ex isa EOFError
                    return msgs
                end
                rethrow()
            end

            isempty(strip(line)) && continue

            local msg
            try
                msg = JSON3.read(line, Dict{String, Any})
            catch ex
                error("failed to parse JSON response line $(repr(line)): $(sprint(showerror, ex))")
            end

            push!(msgs, msg)

            if haskey(msg, "status") && ("done" in msg["status"])
                return msgs
            end
        end

        return msgs
    end

    status = timedwait(() -> istaskdone(reader), timeout_s)
    if status !== :ok
        isopen(sock) && close(sock)
        error("timed out waiting $(timeout_s)s for done-terminated response stream")
    end

    return fetch(reader)
end
