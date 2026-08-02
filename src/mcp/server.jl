# MCP server (stdio) — JSON-RPC 2.0 loop, lifecycle helpers, and transport dispatch.
# Depends on tools, requests, and results.

function mcp_log(msg::AbstractString)
    println(stderr, "[REPLy-MCP] ", msg)
    flush(stderr)
end

# --- Session lifecycle helpers ---

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
    elseif tool_name in ("julia_eval", "julia_complete", "julia_lookup", "julia_load_file", "julia_interrupt")
        return error_result("$tool_name requires a live transport and cannot be dispatched via mcp_call_tool")
    else
        return error_result("Unknown tool: $tool_name")
    end
end

# --- Safety dispatch: scope fence for dangerous eval patterns ---

# Pattern-matched prohibitions for the MCP adapter.
# These guard against accidental or adversarial code execution via the MCP
# adapter when the caller has not explicitly opted in via `allow_unsafe=true`.
# Prohibitions defined in GOVERNANCE.md §3 (BSD Prohibited Behaviors).
const DANGEROUS_EVAL_PATTERNS = [
    r"\brun\(" => "shell execution via run()",
    r"\bpipeline\(" => "shell execution via pipeline()",
    r"\bwrite\(\s*[^\s,]+" => "filesystem write via write()",       # write(path, ...) or write(filename, ...)
    r"\bopen\(.*(?:write|append)" => "filesystem write via open(; write|append)",
    r"\bdownload\(" => "network access via download()",
    r"\bHTTP\.request\(" => "network access via HTTP.request()",
    r"\brm\(" => "filesystem deletion via rm()",
    r"\brmrf\(" => "filesystem deletion via rmrf()",
    r"\bmv\(" => "filesystem rename via mv()",
    r"\bcp\(" => "filesystem copy via cp()",
    r"\bmkpath\(" => "filesystem creation via mkpath()",
    r"\breadchomp\b.*`" => "command execution via backtick or readchomp",
    r"\bread\b.*`" => "command execution via backtick or read",
]

"""
    mcp_check_dangerous_patterns(code::AbstractString) -> Union{Nothing, String}

Check `code` for dangerous eval patterns. Returns `nothing` if the code is safe
(or `allow_unsafe=true` is set), or a human-readable error message describing
the first prohibited pattern found.

Checks are pattern-matched against the raw code string. They are NOT a
security boundary — resource limits and session isolation are the security
boundary. These checks exist as a behavioral guard for the MCP adapter's
default configuration ("fail closed").
"""
function mcp_check_dangerous_patterns(code::AbstractString)
    for (pattern, description) in DANGEROUS_EVAL_PATTERNS
        if occursin(pattern, code)
            return "Code matches prohibited pattern: $description. Set `allow_unsafe=true` to override."
        end
    end
    return nothing
end

# --- Safety dispatch: scope fence for dangerous eval patterns ---


# Execute a Reply `request` through the handler closure directly and convert the
# response vector to an MCP result via `to_result`. Shared by all live tools
# (eval, complete, lookup, load-file, interrupt).
function mcp_dispatch_direct(build_request::Function, args, default_session, handler::Function, to_result::Function)
    request = try
        build_request("mcp-tool-$(time_ns())", args; default_session)
    catch ex
        ex isa ArgumentError || rethrow()
        return error_result(ex.msg)
    end
    msgs = handler(request)
    return to_result(msgs)
end

function mcp_dispatch_eval_direct(args, default_session, handler::Function)
    code = get(args, "code", "")
    allow_unsafe = get(args, "allow_unsafe", false)
    allow_unsafe isa Bool || (allow_unsafe = false)

    # --- PRIMARY OBJECTIVE: enable Julia tool builders to ship structured ---
    # --- REPL interaction, cutting integration time from days to minutes. ---
    # Scope fence: fail closed on dangerous patterns unless explicitly overridden.
    if !isempty(code) && !allow_unsafe
        check_result = mcp_check_dangerous_patterns(code)
        if !isnothing(check_result)
            mcp_log("Safety guard triggered: $check_result")
            return error_result(check_result)
        end
    end

    request = try
        mcp_eval_request("mcp-eval-$(time_ns())", args; default_session)
    catch ex
        ex isa ArgumentError || rethrow()
        return error_result(ex.msg)
    end
    msgs = handler(request)
    return reply_stream_to_mcp_result(msgs)
end

# --- JSON-RPC 2.0 helpers ---

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

# --- JSON-RPC 2.0 request dispatch ---

function process_mcp_request(method::AbstractString, params, id, manager, default_session, handler::Function)
    if method == "initialize"
        return mcp_rpc_result(id, mcp_initialize_result())
    elseif method == "tools/list"
        return mcp_rpc_result(id, Dict("tools" => mcp_tools()))
    elseif method == "tools/call"
        args_container = params isa AbstractDict ? params : Dict{String, Any}()
        name = get(args_container, "name", "")
        args = get(args_container, "arguments", Dict{String, Any}())

        if name == "julia_eval"
            return mcp_rpc_result(id, mcp_dispatch_eval_direct(args, default_session, handler))
        elseif name == "julia_complete"
            return mcp_rpc_result(id, mcp_dispatch_direct(mcp_complete_request, args, default_session, handler, reply_stream_to_json_result))
        elseif name == "julia_lookup"
            return mcp_rpc_result(id, mcp_dispatch_direct(mcp_lookup_request, args, default_session, handler, reply_stream_to_json_result))
        elseif name == "julia_load_file"
            return mcp_rpc_result(id, mcp_dispatch_direct(mcp_load_file_request, args, default_session, handler, reply_stream_to_mcp_result))
        elseif name == "julia_interrupt"
            return mcp_rpc_result(id, mcp_dispatch_direct(mcp_interrupt_request, args, default_session, handler, reply_stream_to_json_result))
        else
            result = mcp_call_tool(String(name), args, manager)
            return mcp_rpc_result(id, result)
        end
    elseif method == "notifications/initialized"
        return nothing
    else
        mcp_log("Unsupported MCP method: $method")
        if !isnothing(id)
            return mcp_rpc_error(id, -32601, "Method not found: $method")
        end
        return nothing
    end
end

# --- Entry point ---

"""
    serve_mcp(; manager=SessionManager(), middleware=default_middleware_stack(), limits=ResourceLimits(), max_message_bytes=DEFAULT_MAX_MESSAGE_BYTES, use_socket=false)

Start a stdio-based MCP server. This function blocks, reading JSON-RPC 2.0
messages from `stdin` and writing responses to `stdout`.

It automatically:
1. Builds an in-process handler via `build_handler` (no TCP loopback).
2. Starts an idle-session sweeper for automatic session cleanup.
3. Handles the MCP `initialize` and `tools/list` handshake.
4. Dispatches `tools/call` requests through the in-process handler.
5. Logs internal errors and diagnostic info to `stderr`.

Use this as the entry point for integrating REPLy with MCP clients like
Claude Desktop or VS Code extensions.

# Keyword arguments
- `use_socket`: If `true`, start a background REPLy TCP server on a random
  loopback port and dispatch through it (legacy TCP loopback mode). This mode
  is retained for testing and comparison. Default: `false`.
"""
function serve_mcp(;
    manager::SessionManager=SessionManager(),
    middleware::Vector{<:AbstractMiddleware}=default_middleware_stack(),
    limits::ResourceLimits=ResourceLimits(),
    max_message_bytes::Int=DEFAULT_MAX_MESSAGE_BYTES,
    use_socket::Bool=false,
)
    state = ServerState(limits, max_message_bytes)

    userver = nothing
    handler = nothing

    if use_socket
        # Legacy TCP loopback mode — retained for testing and comparison.
        userver = serve(; host=ip"127.0.0.1", port=0, manager, middleware, limits, max_message_bytes)
        port = server_port(userver)
        mcp_log("REPLy internal server started on 127.0.0.1:$port")
        handler = function(msg::AbstractDict)
            client = Client("127.0.0.1", port)
            try
                send!(client, msg)
                return collect_until_done(client, String(msg["id"]))
            finally
                disconnect(client)
            end
        end
    else
        # In-process mode — call the handler closure directly, no TCP loopback.
        stack = materialize_middleware_stack(middleware)
        validation_errors = validate_stack(stack)
        if !isempty(validation_errors)
            throw(ArgumentError("middleware stack validation failed:\n  - " * join(validation_errors, "\n  - ")))
        end
        handler = build_handler(; manager, middleware=stack, state)
        start_session_sweeper!(state, manager)
        mcp_log("REPLy in-process handler initialized")
    end

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

            if get(req, "jsonrpc", "") != "2.0"
                mcp_log("MCP protocol error: expected jsonrpc: 2.0")
                continue
            end

            method = get(req, "method", "")
            id = get(req, "id", nothing)
            params = get(req, "params", Dict{String, Any}())

            response = process_mcp_request(String(method), params, id, manager, default_session, handler)
            if !isnothing(response)
                println(stdout, JSON3.write(response))
                flush(stdout)
            end
        end
    finally
        stop_session_sweeper!(state)
        if !isnothing(userver)
            close(userver)
        end
        mcp_log("MCP server shutting down")
    end
end
