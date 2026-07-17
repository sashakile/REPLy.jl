# MCP result converters — map Reply response streams to MCP CallToolResult dicts.
# Transport- and lifecycle-agnostic; pure transformation functions.

"""
Collect Reply messages for `request_id` until the terminal `done` status arrives.

Messages for other request ids are buffered into `pending`, allowing callers to
safely reuse the same transport across interleaved request streams.

If no terminal message arrives within `timeout_seconds`, the transport is closed
and a one-element collection containing a synthetic `["done", "timeout"]` terminal
message is returned. A positive `timeout_seconds` is required.
"""
function collect_reply_stream(
    transport::AbstractTransport,
    request_id::AbstractString;
    pending::AbstractDict{String, Vector{AbstractDict}}=Dict{String, Vector{AbstractDict}}(),
    timeout_seconds::Real=DEFAULT_COLLECT_TIMEOUT_SECONDS,
)
    timeout_seconds > 0 || throw(ArgumentError("timeout_seconds must be positive, got $timeout_seconds"))

    task = @async begin
        collected = AbstractDict[]
        while true
            buffered = get(pending, request_id, nothing)
            if buffered isa Vector{AbstractDict} && !isempty(buffered)
                msg = popfirst!(buffered)
                if isempty(buffered)
                    delete!(pending, request_id)
                end
            else
                msg = receive(transport)
                isnothing(msg) && throw(EOFError())
                msg_id = get(msg, "id", nothing)
                msg_id isa AbstractString || continue

                if msg_id != request_id
                    push!(get!(pending, msg_id, AbstractDict[]), msg)
                    continue
                end
            end

            push!(collected, msg)

            status = get(msg, "status", nothing)
            if status isa AbstractVector && ("done" in status)
                return collected
            end
        end
    end

    timed_out = timedwait(() -> istaskdone(task), Float64(timeout_seconds)) === :timed_out

    if timed_out
        try close(transport) catch end
        try wait(task) catch end
        return [Dict{String, Any}(
            "id" => String(request_id),
            "status" => ["done", "timeout"],
            "err" => "Timed out after $(timeout_seconds)s waiting for eval response",
        )]
    end

    return fetch(task)
end

"""
Map a complete Reply response stream to an MCP `CallToolResult`.

Status precedence is `timeout` > `interrupted` > `error` > success so terminal
non-success modes produce deterministic MCP output even when Reply status arrays
contain multiple flags.
"""
function reply_stream_to_mcp_result(msgs::AbstractVector{<:AbstractDict})
    isempty(msgs) && throw(ArgumentError("reply stream must not be empty"))

    content = Dict{String, Any}[]
    terminal = nothing

    for msg in msgs
        status = get(msg, "status", nothing)
        if status isa AbstractVector
            terminal = msg
            continue
        end

        if haskey(msg, "out")
            push!(content, text_block(String(msg["out"])))
        end
        if haskey(msg, "err")
            push!(content, text_block(String(msg["err"])))
        end
        if haskey(msg, "value") && !isnothing(msg["value"])
            push!(content, text_block(String(msg["value"])))
        elseif haskey(msg, "repr-error")
            push!(content, text_block("<repr failed: $(msg["repr-error"])>"))
        end
    end

    isnothing(terminal) && throw(ArgumentError("reply stream is missing terminal done status"))

    status = Set(String.(get(terminal, "status", Any[])))
    if "timeout" in status
        return error_result("Evaluation timed out")
    elseif "interrupted" in status
        return error_result("Interrupted")
    elseif "error" in status
        err = String(get(terminal, "err", "Reply request failed"))
        push!(content, text_block(err))

        stacktrace = format_stacktrace(get(terminal, "stacktrace", nothing))
        if !isnothing(stacktrace)
            push!(content, text_block(stacktrace))
        end
        return Dict("isError" => true, "content" => content)
    end

    return Dict("isError" => false, "content" => content)
end

"""
Convert a reply stream to an MCP result whose single text block is the JSON
encoding of all response payload fields (everything except `id`/`status`),
merged across non-terminal messages. Used for structured ops (complete, lookup,
interrupt) whose useful output is op-specific fields rather than free text.
Terminal `error`/`timeout` statuses map to MCP error results.
"""
function reply_stream_to_json_result(msgs)
    isempty(msgs) && throw(ArgumentError("reply stream must not be empty"))

    terminal = nothing
    payload = Dict{String, Any}()
    for msg in msgs
        status = get(msg, "status", nothing)
        if status isa AbstractVector
            terminal = msg
            continue
        end
        for (k, v) in pairs(msg)
            String(k) == "id" && continue
            payload[String(k)] = v
        end
    end

    isnothing(terminal) && throw(ArgumentError("reply stream is missing terminal done status"))

    status = Set(String.(get(terminal, "status", Any[])))
    if "timeout" in status
        return error_result("Request timed out")
    elseif "error" in status
        return error_result(String(get(terminal, "err", "Reply request failed")))
    end

    return Dict("isError" => false, "content" => [text_block(JSON3.write(payload))])
end
