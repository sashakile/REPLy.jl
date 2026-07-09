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
    mcp_close_session_result(manager, session_name) -> CallToolResult

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
`julia_close_session`) to their respective lifecycle helpers. Returns an error
for transport-backed tools (`julia_eval`, `julia_complete`, `julia_lookup`,
`julia_load_file`, `julia_interrupt`) — these require a live transport and are
dispatched by the full adapter loop (`process_mcp_request`) — and for unknown
tool names.

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
    # Transport-backed tools require a live transport and are dispatched by the
    # full adapter loop (process_mcp_request), not this static helper.
    elseif tool_name in ("julia_eval", "julia_complete", "julia_lookup", "julia_load_file", "julia_interrupt")
        return error_result("$tool_name requires a live transport and cannot be dispatched via mcp_call_tool")
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
    pending::AbstractDict{String, Vector{AbstractDict}}=Dict{String, Vector{AbstractDict}}(),
    timeout_seconds::Real=DEFAULT_COLLECT_TIMEOUT_SECONDS,
)
    timeout_seconds > 0 || throw(ArgumentError("timeout_seconds must be positive, got $timeout_seconds"))

    # `collected` is owned exclusively by the async task — no shared-state race.
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

# --- MCP Server (stdio) ---

"""
    serve_mcp(; manager=SessionManager(), middleware=default_middleware_stack(), limits=ResourceLimits(), max_message_bytes=DEFAULT_MAX_MESSAGE_BYTES)

Start a stdio-based MCP server. This function blocks, reading JSON-RPC 2.0
messages from `stdin` and writing responses to `stdout`.

It automatically:
1. Starts a background REPLy TCP server on a random loopback port.
2. Handles the MCP `initialize` and `tools/list` handshake.
3. Dispatches `tools/call` requests.
4. Routes `julia_eval` to the background REPLy server.
5. Logs internal errors and diagnostic info to `stderr`.

Use this as the entry point for integrating REPLy with MCP clients like
Claude Desktop or VS Code extensions.
"""
function serve_mcp(;
    manager::SessionManager=SessionManager(),
    middleware::Vector{<:AbstractMiddleware}=default_middleware_stack(),
    limits::ResourceLimits=ResourceLimits(),
    max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES
)
    # Start internal REPLy server on loopback, random port.
    server = serve(; host=ip"127.0.0.1", port=0, manager, middleware, limits, max_message_bytes)
    port = server_port(server)
    mcp_log("REPLy internal server started on 127.0.0.1:$port")

    default_session = mcp_ensure_default_session!(manager)

    try
        while !eof(stdin)
            line = readline(stdin)
            isempty(strip(line)) && continue

            req = try
                JSON3.read(line, Dict{String, Any})
            catch ex
                mcp_log("MCP parse error: $ex")
                continue
            end

            # Basic JSON-RPC 2.0 check
            if get(req, "jsonrpc", "") != "2.0"
                mcp_log("MCP protocol error: expected jsonrpc: 2.0")
                continue
            end

            method = get(req, "method", "")
            id = get(req, "id", nothing)
            params = get(req, "params", Dict{String, Any}())

            response = process_mcp_request(String(method), params, id, manager, default_session, port)
            if !isnothing(response)
                println(stdout, JSON3.write(response))
                flush(stdout)
            end
        end
    finally
        mcp_log("MCP server shutting down")
        close(server)
    end
end

function mcp_log(msg::AbstractString)
    println(stderr, "[REPLy-MCP] ", msg)
    flush(stderr)
end

function process_mcp_request(method::AbstractString, params, id, manager, default_session, port)
    if method == "initialize"
        return mcp_rpc_result(id, mcp_initialize_result())
    elseif method == "tools/list"
        return mcp_rpc_result(id, Dict("tools" => mcp_tools()))
    elseif method == "tools/call"
        # params must be a dict for tools/call
        args_container = params isa AbstractDict ? params : Dict{String, Any}()
        name = get(args_container, "name", "")
        args = get(args_container, "arguments", Dict{String, Any}())

        if name == "julia_eval"
            return mcp_rpc_result(id, mcp_dispatch_eval(args, default_session, port))
        elseif name == "julia_complete"
            return mcp_rpc_result(id, mcp_dispatch_tool(mcp_complete_request, args, default_session, port, reply_stream_to_json_result))
        elseif name == "julia_lookup"
            return mcp_rpc_result(id, mcp_dispatch_tool(mcp_lookup_request, args, default_session, port, reply_stream_to_json_result))
        elseif name == "julia_load_file"
            return mcp_rpc_result(id, mcp_dispatch_tool(mcp_load_file_request, args, default_session, port, reply_stream_to_mcp_result))
        elseif name == "julia_interrupt"
            return mcp_rpc_result(id, mcp_dispatch_tool(mcp_interrupt_request, args, default_session, port, reply_stream_to_json_result))
        else
            # Forward to static lifecycle helpers
            result = mcp_call_tool(String(name), args, manager)
            return mcp_rpc_result(id, result)
        end
    elseif method == "notifications/initialized"
        return nothing # No-op notification
    else
        mcp_log("Unsupported MCP method: $method")
        if !isnothing(id)
            return mcp_rpc_error(id, -32601, "Method not found: $method")
        end
        return nothing
    end
end

function mcp_rpc_result(id, result)
    isnothing(id) && return nothing
    return Dict(
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => result
    )
end

function mcp_rpc_error(id, code, message)
    isnothing(id) && return nothing
    return Dict(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => Dict("code" => code, "message" => message)
    )
end

# Execute a Reply `request` over the internal loopback transport and convert the
# collected reply stream to an MCP result via `to_result`. Shared by all live
# tools (eval, complete, lookup, load-file, interrupt).
function mcp_dispatch_over_transport(request::AbstractDict, port::Integer, to_result::Function)
    try
        conn = connect(ip"127.0.0.1", port)
        transport = JSONTransport(conn, ReentrantLock())
        try
            send!(transport, request)
            msgs = collect_reply_stream(transport, String(request["id"]))
            return to_result(msgs)
        finally
            close(transport)
        end
    catch ex
        mcp_log("Internal request error: $ex")
        return error_result("Internal server error during request")
    end
end

# Build a Reply request via `build_request` (an MCP-args → Reply-request mapper),
# then dispatch it over the transport, converting the result with `to_result`.
# ArgumentErrors from `build_request` are surfaced as MCP error results.
function mcp_dispatch_tool(build_request::Function, args, default_session, port::Integer, to_result::Function)
    request = try
        build_request("mcp-tool-$(time_ns())", args; default_session)
    catch ex
        ex isa ArgumentError || rethrow()
        return error_result(ex.msg)
    end
    return mcp_dispatch_over_transport(request, port, to_result)
end

function mcp_dispatch_eval(args, default_session, port)
    request = try
        mcp_eval_request("mcp-eval-$(time_ns())", args; default_session)
    catch ex
        ex isa ArgumentError || rethrow()
        return error_result(ex.msg)
    end
    return mcp_dispatch_over_transport(request, port, reply_stream_to_mcp_result)
end

# Resolve an MCP session argument to a Reply session name that is guaranteed to
# exist: falls back to `default_session` when omitted or when "ephemeral" is
# requested (introspection ops like complete/lookup need a real session module).
function mcp_resolve_session(args, default_session)
    session = get(args, "session", default_session)
    session isa AbstractString || throw(ArgumentError("session must be a string when provided"))
    return session == MCP_EPHEMERAL_SESSION ? default_session : session
end

"""Build a Reply `complete` request from MCP `julia_complete` arguments."""
function mcp_complete_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    code = get(args, "code", nothing)
    code isa AbstractString || throw(ArgumentError("julia_complete requires a string code field"))
    pos = get(args, "pos", nothing)
    pos isa Integer || throw(ArgumentError("julia_complete requires an integer pos field"))
    return Dict{String, Any}(
        "op" => "complete", "id" => request_id,
        "code" => code, "pos" => pos,
        "session" => mcp_resolve_session(args, default_session),
    )
end

"""Build a Reply `lookup` request from MCP `julia_lookup` arguments."""
function mcp_lookup_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    symbol = get(args, "symbol", nothing)
    symbol isa AbstractString || throw(ArgumentError("julia_lookup requires a string symbol field"))
    request = Dict{String, Any}(
        "op" => "lookup", "id" => request_id,
        "symbol" => symbol,
        "session" => mcp_resolve_session(args, default_session),
    )
    module_name = get(args, "module", nothing)
    if !isnothing(module_name)
        module_name isa AbstractString || throw(ArgumentError("module must be a string when provided"))
        request["module"] = module_name
    end
    return request
end

"""Build a Reply `load-file` request from MCP `julia_load_file` arguments."""
function mcp_load_file_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    file = get(args, "file", nothing)
    file isa AbstractString || throw(ArgumentError("julia_load_file requires a string file field"))
    request = Dict{String, Any}("op" => "load-file", "id" => request_id, "file" => file)
    session = get(args, "session", default_session)
    if session isa AbstractString
        session != MCP_EPHEMERAL_SESSION && (request["session"] = session)
    elseif !isnothing(session)
        throw(ArgumentError("session must be a string when provided"))
    end
    return request
end

"""Build a Reply `interrupt` request from MCP `julia_interrupt` arguments."""
function mcp_interrupt_request(request_id::AbstractString, args::AbstractDict; default_session::AbstractString)
    session = get(args, "session", nothing)
    session isa AbstractString || throw(ArgumentError("julia_interrupt requires a string session field"))
    isempty(session) && throw(ArgumentError("julia_interrupt requires a non-empty session field"))
    request = Dict{String, Any}("op" => "interrupt", "id" => request_id, "session" => session)
    interrupt_id = get(args, "interrupt_id", nothing)
    if !isnothing(interrupt_id)
        parsed = interrupt_id isa Integer ? Int(interrupt_id) : tryparse(Int, string(interrupt_id))
        isnothing(parsed) && throw(ArgumentError("interrupt_id must be an integer"))
        request["interrupt-id"] = parsed
    end
    return request
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
