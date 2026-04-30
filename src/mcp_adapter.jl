const MCP_PROTOCOL_VERSION = "2024-11-05"
const MCP_EPHEMERAL_SESSION = "ephemeral"
const MCP_DEFAULT_SESSION_NAME = "mcp-default"
const DEFAULT_COLLECT_TIMEOUT_SECONDS = 30.0

"""Type alias for the MCP `CallToolResult` dict shape returned by adapter helpers."""
const CallToolResult = Dict{String,Any}

"""Return the MCP `initialize` result advertised by the reference adapter helpers."""
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

"""Return the static MCP tool catalog exposed by the reference adapter."""
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

"""
Build a Reply `eval` request from MCP `julia_eval` arguments.

When `session` is omitted, the adapter routes to `default_session`.
When `session == "ephemeral"`, the Reply request omits the `session` field.
This helper rejects invalid adapter inputs before emitting a Reply message.
"""
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
        throw(ArgumentError("module field is not yet supported (CORR-005)"))
    end

    timeout_ms = get(args, "timeout_ms", nothing)
    if !isnothing(timeout_ms)
        throw(ArgumentError("timeout_ms field is not yet supported (CORR-005)"))
    end

    return request
end

"""Return a standard MCP 'not yet implemented' error result for stub tools."""
function mcp_stub_result(tool_name::AbstractString)
    # Tracking reference: DRAFT-004
    return error_result("$tool_name is not yet implemented")
end

"""
    mcp_ensure_default_session!(manager; name=MCP_DEFAULT_SESSION_NAME) -> String

Ensure the adapter's persistent default session exists in `manager`.
Creates it if absent; returns the canonical UUID of the session (whether
newly created or already existing). The `name` alias is registered so the
session can also be found by name, but the UUID is the canonical identity
used for routing.
Thread-safe: the check-and-create is performed atomically under a single lock
acquisition via `get_or_create_named_session!`.
"""
function mcp_ensure_default_session!(manager::SessionManager; name::AbstractString=MCP_DEFAULT_SESSION_NAME)
    session = get_or_create_named_session!(manager, name)
    return session_id(session)
end

"""
    mcp_new_session_result(manager; max_sessions=typemax(Int)) -> CallToolResult

Create a new unnamed session and return its canonical UUID in a non-error
`CallToolResult`. The UUID is the spec-compliant identity for all subsequent ops.
Returns an error result when the session limit is reached.
"""
function mcp_new_session_result(manager::SessionManager; max_sessions::Int=typemax(Int))
    session = create_named_session_if_within_limit!(manager, "", max_sessions)
    isnothing(session) && return error_result("Session limit reached")
    uuid = session_id(session)
    return CallToolResult("isError" => false, "content" => [text_block("Session: $uuid")])
end

"""
    mcp_list_sessions_result(manager) -> CallToolResult

List all named sessions in `manager` and return their canonical UUIDs (with
optional name aliases) as a `CallToolResult`. Returns `"[]"` when no sessions
exist. Each line is `"<uuid>"` for unnamed sessions or `"<uuid> (<name>)"` for
sessions that have a name alias.
"""
function mcp_list_sessions_result(manager::SessionManager)
    sessions = sort(list_named_sessions(manager); by=s -> session_id(s))
    if isempty(sessions)
        return CallToolResult("isError" => false, "content" => [text_block("[]")])
    end
    lines = map(sessions) do s
        uuid = session_id(s)
        name = session_name(s)
        isempty(name) ? uuid : "$uuid ($name)"
    end
    return CallToolResult("isError" => false, "content" => [text_block(join(lines, "\n"))])
end

"""
    mcp_close_session_result(manager, session_id_or_name) -> CallToolResult

Close the session identified by UUID or name alias and return a non-error
`CallToolResult`. Returns an error result if the session does not exist. The
existence check and removal are performed atomically via `destroy_named_session!`,
which returns `true` only when it actually removed an entry.
"""
function mcp_close_session_result(manager::SessionManager, session_name::AbstractString)
    removed = destroy_named_session!(manager, String(session_name))
    if !removed
        return error_result("Session not found: $session_name")
    end
    return CallToolResult("isError" => false, "content" => [text_block("Closed session: $session_name")])
end

"""
    mcp_call_tool(tool_name, args, manager; max_sessions=typemax(Int)) -> CallToolResult

Dispatch an MCP `tools/call` request to the appropriate adapter helper.

Routes session lifecycle tools (`julia_new_session`, `julia_list_sessions`,
`julia_close_session`) to their respective lifecycle helpers. Returns a stub
error for tools that are not yet implemented (`julia_complete`, `julia_lookup`,
`julia_load_file`, `julia_interrupt`). Returns an error for `julia_eval` (which
requires a live transport and is handled by the full adapter loop) and for
unknown tool names.

`max_sessions` is forwarded to `mcp_new_session_result` to enforce the server
session limit when creating sessions from the MCP adapter.
"""
function mcp_call_tool(tool_name::AbstractString, args::AbstractDict, manager::SessionManager; max_sessions::Int=typemax(Int))
    # Lifecycle tools — primary dispatch targets
    if tool_name == "julia_new_session"
        return mcp_new_session_result(manager; max_sessions)
    elseif tool_name == "julia_list_sessions"
        return mcp_list_sessions_result(manager)
    elseif tool_name == "julia_close_session"
        session = get(args, "session", nothing)
        session isa AbstractString ||
            return error_result("julia_close_session requires a string session argument")
        isempty(session) &&
            return error_result("julia_close_session requires a non-empty session argument")
        err = validate_session_name(session)
        isnothing(err) || return error_result(err)
        return mcp_close_session_result(manager, session)
    # Stub tools — not yet implemented
    elseif tool_name in ("julia_complete", "julia_lookup", "julia_load_file", "julia_interrupt")
        return mcp_stub_result(tool_name)
    # julia_eval requires a live transport; cannot be dispatched statically
    elseif tool_name == "julia_eval"
        return error_result("julia_eval requires a live transport and cannot be dispatched via mcp_call_tool")
    else
        return error_result("Unknown tool: $tool_name")
    end
end

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
    pending::AbstractDict{String, Vector{Dict{String, Any}}}=Dict{String, Vector{Dict{String, Any}}}(),
    timeout_seconds::Real=DEFAULT_COLLECT_TIMEOUT_SECONDS,
)
    timeout_seconds > 0 || throw(ArgumentError("timeout_seconds must be positive, got $timeout_seconds"))

    # `collected` is owned exclusively by the async task — no shared-state race.
    task = @async begin
        collected = Dict{String, Any}[]
        while true
            buffered = get(pending, request_id, nothing)
            if buffered isa Vector{Dict{String, Any}} && !isempty(buffered)
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
                    push!(get!(pending, msg_id, Dict{String, Any}[]), msg)
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
