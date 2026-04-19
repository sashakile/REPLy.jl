const MCP_PROTOCOL_VERSION = "2024-11-05"
const MCP_EPHEMERAL_SESSION = "ephemeral"

function mcp_initialize_result()
    return Dict{String, Any}(
        "protocolVersion" => MCP_PROTOCOL_VERSION,
        "capabilities" => Dict{String, Any}(),
        "serverInfo" => Dict(
            "name" => protocol_name(),
            "version" => version_string(),
        ),
    )
end

function mcp_tools()
    return Dict{String, Any}[
        mcp_tool(
            "julia_eval",
            "Evaluate Julia code through REPLy.",
            Dict(
                "code" => string_schema("Julia code to evaluate."),
                "session" => string_schema("Optional session id. Use 'ephemeral' for one-shot eval."),
                "module" => string_schema("Optional module path to evaluate within."),
                "timeout_ms" => integer_schema("Optional timeout in milliseconds."),
            );
            required=["code"],
        ),
        mcp_tool(
            "julia_complete",
            "Return completions for Julia code.",
            Dict(
                "code" => string_schema("Source text to complete."),
                "pos" => integer_schema("Cursor position within code."),
                "session" => string_schema("Optional session id."),
            );
            required=["code", "pos"],
        ),
        mcp_tool(
            "julia_lookup",
            "Look up Julia symbol documentation.",
            Dict(
                "symbol" => string_schema("Symbol to inspect."),
                "module" => string_schema("Optional module path for symbol resolution."),
                "session" => string_schema("Optional session id."),
            );
            required=["symbol"],
        ),
        mcp_tool(
            "julia_load_file",
            "Load a Julia source file.",
            Dict(
                "file" => string_schema("Path to a Julia source file."),
                "session" => string_schema("Optional session id. Use 'ephemeral' for one-shot load."),
            );
            required=["file"],
        ),
        mcp_tool(
            "julia_interrupt",
            "Interrupt one or more in-flight evaluations.",
            Dict(
                "session" => string_schema("Session whose evals should be interrupted."),
                "interrupt_id" => string_schema("Optional request id to interrupt."),
            );
            required=["session"],
        ),
        mcp_tool(
            "julia_new_session",
            "Create a new persistent Julia session.",
            Dict{String, Any}();
            required=String[],
        ),
        mcp_tool(
            "julia_list_sessions",
            "List active Julia sessions.",
            Dict{String, Any}();
            required=String[],
        ),
        mcp_tool(
            "julia_close_session",
            "Close a persistent Julia session.",
            Dict("session" => string_schema("Session id to close."));
            required=["session"],
        ),
    ]
end

function mcp_eval_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    code = get(args, "code", nothing)
    code isa AbstractString || throw(ArgumentError("julia_eval requires a string code field"))

    request = Dict{String, Any}(
        "op" => "eval",
        "id" => request_id,
        "code" => code,
        "allow-stdin" => false,
    )

    session = get(args, "session", default_session)
    if session isa AbstractString
        if session != MCP_EPHEMERAL_SESSION
            request["session"] = session
        end
    elseif !isnothing(session)
        throw(ArgumentError("session must be a string when provided"))
    end

    module_name = get(args, "module", nothing)
    if !isnothing(module_name)
        module_name isa AbstractString || throw(ArgumentError("module must be a string when provided"))
        request["module"] = module_name
    end

    timeout_ms = get(args, "timeout_ms", nothing)
    if !isnothing(timeout_ms)
        timeout_ms isa Integer || throw(ArgumentError("timeout_ms must be an integer when provided"))
        request["timeout-ms"] = timeout_ms
    end

    return request
end

function collect_reply_stream(transport::AbstractTransport, request_id::AbstractString)
    msgs = Dict{String, Any}[]

    while true
        msg = receive(transport)
        isnothing(msg) && throw(EOFError())
        get(msg, "id", nothing) == request_id || continue
        push!(msgs, msg)

        status = get(msg, "status", nothing)
        if status isa AbstractVector && ("done" in status)
            return msgs
        end
    end
end

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
        if haskey(msg, "value")
            push!(content, text_block(String(msg["value"])))
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

function mcp_tool(name::AbstractString, description::AbstractString, properties::AbstractDict; required::Vector{String})
    return Dict{String, Any}(
        "name" => name,
        "description" => description,
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict{String, Any}(String(k) => v for (k, v) in pairs(properties)),
            "required" => required,
            "additionalProperties" => false,
        ),
    )
end

string_schema(description::AbstractString) = Dict("type" => "string", "description" => description)
integer_schema(description::AbstractString) = Dict("type" => "integer", "description" => description)
text_block(text::AbstractString) = Dict("type" => "text", "text" => text)
error_result(text::AbstractString) = Dict("isError" => true, "content" => [text_block(text)])

function format_stacktrace(frames)
    isnothing(frames) && return nothing
    frames isa AbstractVector || return string(frames)
    isempty(frames) && return nothing

    rendered = String[]
    for frame in frames
        if frame isa AbstractDict
            func = get(frame, "func", "unknown")
            file = get(frame, "file", "unknown")
            line = get(frame, "line", "?")
            push!(rendered, string(func, " at ", file, ":", line))
        else
            push!(rendered, string(frame))
        end
    end

    return join(rendered, "\n")
end
