# How-to: Use the MCP Adapter

REPLy ships with a built-in adapter layer for the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/). The adapter exposes Julia evaluation and session management as MCP tools, so any MCP-compatible client (Claude Desktop, VS Code MCP extensions, etc.) can use REPLy as a code-execution backend.

## MCP Tools Catalog

The adapter exposes 8 tools via `mcp_tools()`:

| Tool | Status | Description |
|---|---|---|
| `julia_eval` | Implemented | Evaluate Julia code in a session |
| `julia_new_session` | Implemented | Create a new persistent session |
| `julia_list_sessions` | Implemented | List active sessions |
| `julia_close_session` | Implemented | Close a persistent session |
| `julia_complete` | Stub | Tab completions (not yet implemented) |
| `julia_lookup` | Stub | Symbol documentation (not yet implemented) |
| `julia_load_file` | Stub | Load a Julia source file (not yet implemented) |
| `julia_interrupt` | Stub | Interrupt in-flight evaluations (not yet implemented) |

Stub tools return a structured error response rather than silently failing.

## Initializing the MCP Handshake

Return the MCP `initialize` response from `mcp_initialize_result()`:

```julia
using REPLy: mcp_initialize_result

result = mcp_initialize_result()
# Dict with "protocolVersion", "capabilities", and "serverInfo"
```

Return the tool catalog from `mcp_tools()`:

```julia
using REPLy: mcp_tools

tools = mcp_tools()
# Vector of tool descriptor dicts, one per tool
```

## Dispatching Tool Calls

Use `mcp_call_tool` to route `tools/call` requests to the appropriate handler:

```julia
using REPLy: mcp_call_tool
using REPLy

manager = REPLy.SessionManager()

# Create a new session
result = mcp_call_tool("julia_new_session", Dict(), manager)
# result["isError"] == false
# result["content"][1]["text"] == "Session: mcp-<uuid>"

# List sessions
result = mcp_call_tool("julia_list_sessions", Dict(), manager)

# Close a session
result = mcp_call_tool("julia_close_session", Dict("session" => "my-session"), manager)
```

`REPLy.SessionManager` is the lower-level server embedding API used by the adapter helpers.

`julia_eval` cannot be dispatched via `mcp_call_tool` because it requires a live transport to stream results. Use `mcp_eval_request` + `collect_reply_stream` instead (see below).

## Evaluating Code

Build a REPLy eval request from MCP arguments:

```julia
using REPLy: mcp_eval_request, mcp_ensure_default_session!
using REPLy

manager = REPLy.SessionManager()
default_session = mcp_ensure_default_session!(manager)  # "mcp-default"

# Build the request (validates required fields, rejects unsupported options)
request = mcp_eval_request("req-1", Dict("code" => "1 + 1"); default_session=default_session)
```

Then create a transport, send the request, and collect the response stream:

```julia
using Sockets
using REPLy: collect_reply_stream, reply_stream_to_mcp_result

# Connect to the running REPLy server and wrap in a JSONTransport
conn = connect(ip"127.0.0.1", 5555)
transport = JSONTransport(conn, ReentrantLock())

send(transport, request)  # send the request first
msgs = collect_reply_stream(transport, "req-1")
result = reply_stream_to_mcp_result(msgs)
# result["isError"] == false
# result["content"] holds out/value/err blocks
close(transport)
```

For Unix domain socket servers (started with `socket_path=`), replace the `connect` call:

```julia
conn = connect(socket_path)
transport = JSONTransport(conn, ReentrantLock())
```

### Session routing

The `session` argument in `julia_eval` controls routing:

- Omitted or `default_session` value → routed to the persistent default session (`"mcp-default"`)
- `"ephemeral"` → routed ephemerally (no state preserved between calls)
- Any other session name → routed to that named session

```julia
# Ephemeral (one-shot, no persistent state)
request = mcp_eval_request("req-2", Dict("code" => "x = 10", "session" => "ephemeral");
                            default_session=default_session)

# Specific named session
request = mcp_eval_request("req-3", Dict("code" => "x", "session" => "my-session");
                            default_session=default_session)
```

## Timeouts

`collect_reply_stream` has a configurable timeout (default `DEFAULT_COLLECT_TIMEOUT_SECONDS` = 30 seconds). On timeout, the transport is closed and a synthetic terminal message is returned with `status == ["done", "timeout"]`:

```julia
using REPLy: collect_reply_stream, DEFAULT_COLLECT_TIMEOUT_SECONDS

msgs = collect_reply_stream(transport, "req-1"; timeout_seconds=10.0)
result = reply_stream_to_mcp_result(msgs)
# On timeout: result["isError"] == true, result["content"][1]["text"] == "Evaluation timed out"
```

!!! note
    When inspecting `msgs` directly (before passing to `reply_stream_to_mcp_result`), the
    raw timeout message also includes an `"err"` field containing the wait duration, e.g.
    `"Timed out after 10.0s waiting for eval response"`. This detail is collapsed into the
    human-readable `"Evaluation timed out"` string by `reply_stream_to_mcp_result`.

## Session Management via MCP

The lifecycle helpers operate directly on a `REPLy.SessionManager`:

```julia
using REPLy: mcp_new_session_result, mcp_list_sessions_result, mcp_close_session_result
using REPLy

manager = REPLy.SessionManager()

# Create
result = mcp_new_session_result(manager)
session_name = match(r"Session: (mcp-\S+)", result["content"][1]["text"]).captures[1]

# List
result = mcp_list_sessions_result(manager)

# Close
result = mcp_close_session_result(manager, session_name)
# result["isError"] is false on success, true if the session is not found
```

The default session can be lazily created with `mcp_ensure_default_session!`, which is a no-op if the session already exists (thread-safe):

```julia
using REPLy: mcp_ensure_default_session!

# Idempotent — safe to call multiple times
session_name = mcp_ensure_default_session!(manager)  # "mcp-default"
session_name = mcp_ensure_default_session!(manager; name="my-default")
```

## Constants Reference

| Constant | Value | Description |
|---|---|---|
| `MCP_PROTOCOL_VERSION` | `"2024-11-05"` | MCP protocol version advertised in `initialize` |
| `MCP_DEFAULT_SESSION_NAME` | `"mcp-default"` | Name of the adapter's persistent default session |
| `MCP_EPHEMERAL_SESSION` | `"ephemeral"` | Session sentinel for one-shot (stateless) evaluation |
| `DEFAULT_COLLECT_TIMEOUT_SECONDS` | `30.0` | Default timeout for `collect_reply_stream` |
| `DEFAULT_CLOSE_GRACE_SECONDS` | `5.0` | Grace window (s) for `Base.close(server)` |

## End-to-End Example

!!! note "Architectural constraint: eval requires a live transport"
    `julia_eval` cannot be routed through `mcp_call_tool` because it needs to stream results
    over a live transport connection. All other tools (`julia_new_session`, `julia_list_sessions`,
    `julia_close_session`) go through `mcp_call_tool` directly.

A minimal MCP dispatch loop:

```julia
using Sockets
using REPLy: mcp_initialize_result, mcp_tools, mcp_call_tool
using REPLy: mcp_ensure_default_session!, mcp_eval_request
using REPLy: collect_reply_stream, reply_stream_to_mcp_result
using REPLy

manager = REPLy.SessionManager()
default_session = mcp_ensure_default_session!(manager)

# Step 1: MCP initialize handshake
init_result = mcp_initialize_result()

# Step 2: Advertise tools
tools = mcp_tools()

# Step 3: Dispatch incoming tool calls
function dispatch(tool_name::String, arguments::Dict)
    if tool_name == "julia_eval"
        # eval requires a live transport — open a fresh connection per call
        conn = connect(ip"127.0.0.1", 5555)
        transport = JSONTransport(conn, ReentrantLock())
        request = mcp_eval_request("req-$(time_ns())", arguments; default_session)
        try
            send(transport, request)
            msgs = collect_reply_stream(transport, request["id"])
            return reply_stream_to_mcp_result(msgs)
        finally
            close(transport)
        end
    else
        # All other lifecycle tools go through mcp_call_tool
        return mcp_call_tool(tool_name, arguments, manager)
    end
end

# Example dispatch
result = dispatch("julia_eval", Dict("code" => "1 + 1"))
# result["content"][1]["text"] == "2"

result = dispatch("julia_new_session", Dict())
# result["content"][1]["text"] == "Session: mcp-<uuid>"
```

## See Also

- [How-to: Manage Persistent Sessions](howto-sessions.md) — session naming, lifecycle states, and idle sweep
