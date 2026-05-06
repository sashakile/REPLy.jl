# How-to: Use the MCP Adapter

REPLy ships with a built-in adapter layer for the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/). The adapter exposes Julia evaluation and session management as MCP tools, so any MCP-compatible client (Claude Desktop, VS Code MCP extensions, etc.) can use REPLy as a code-execution backend.

## Quick Start (Recommended)

The simplest way to use REPLy as an MCP server is via the `REPLy.serve_mcp()` entry point. This starts a stdio-based MCP server that handles the protocol handshake and tool dispatch automatically.

### Configuring Claude Desktop

Add the following to your `claude_desktop_config.json` (usually found in `~/Library/Application Support/Claude/` on macOS or `%APPDATA%\Claude\` on Windows):

```json
{
  "mcpServers": {
    "julia": {
      "command": "julia",
      "args": [
        "--project=/path/to/REPLy.jl",
        "-e",
        "using REPLy; REPLy.serve_mcp()"
      ]
    }
  }
}
```

Replace `/path/to/REPLy.jl` with the actual path to the REPLy.jl repository. Once configured, restart Claude Desktop, and you will see the `julia_eval` and other tools available.

## Programmatic Usage

If you want to start the MCP server from within a larger Julia application:

```julia
using REPLy

# This blocks and communicates over stdin/stdout
REPLy.serve_mcp()
```

You can customize the underlying REPLy server (limits, middleware, etc.) by passing arguments to `serve_mcp`:

```julia
using REPLy

REPLy.serve_mcp(
    limits=ResourceLimits(max_connections=5),
    max_message_bytes=2_000_000
)
```

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
# result["content"][1]["text"] == "Session: <uuid>"  # bare UUID4, no "mcp-" prefix

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
default_session = mcp_ensure_default_session!(manager)  # returns UUID of the session, not the name

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

send!(transport, request)  # send the request first
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
uuid = match(r"Session: (\S+)", result["content"][1]["text"]).captures[1]
# uuid is a bare UUID4 string (e.g. "f47ac10b-58cc-4372-a567-0e02b2c3d479")

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
session_uuid = mcp_ensure_default_session!(manager)  # returns UUID (e.g. "f47ac10b-...")
session_uuid = mcp_ensure_default_session!(manager; name="my-default")
```

## Constants Reference

| Constant | Value | Description |
|---|---|---|
| `MCP_PROTOCOL_VERSION` | `"2024-11-05"` | MCP protocol version advertised in `initialize` |
| `MCP_DEFAULT_SESSION_NAME` | `"mcp-default"` | Name of the adapter's persistent default session |
| `MCP_EPHEMERAL_SESSION` | `"ephemeral"` | Session sentinel for one-shot (stateless) evaluation |
| `DEFAULT_COLLECT_TIMEOUT_SECONDS` | `30.0` | Default timeout for `collect_reply_stream` |
| `DEFAULT_CLOSE_GRACE_SECONDS` | `5.0` | Grace window (s) for `Base.close(server)` |

- [How-to: Manage Persistent Sessions](howto-sessions.md) — session naming, lifecycle states, and idle sweep
