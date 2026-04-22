module REPLy

using JSON3
using REPL
using Sockets

export protocol_name, version_string
export AbstractTransport, JSONTransport, MessageTooLargeError, close, done_response,
    error_response, receive, response_message, send!, validate_request,
    DEFAULT_MAX_MESSAGE_BYTES, DEFAULT_MAX_REPR_BYTES, OUTPUT_TRUNCATION_MARKER,
    truncate_output
export build_handler, serve, server_port, server_socket_path
export get_or_create_named_session!
export RequestContext, HandlerContext, dispatch_middleware
export validate_session_name, MAX_SESSION_NAME_BYTES
export SessionState, SessionIdle, SessionRunning, SessionClosed
export session_state, session_eval_task, session_last_active_at
export begin_eval!, end_eval!, try_begin_eval!, sweep_idle_sessions!
export collect_reply_stream, mcp_eval_request, mcp_initialize_result, mcp_tools,
    reply_stream_to_mcp_result, DEFAULT_COLLECT_TIMEOUT_SECONDS, DEFAULT_CLOSE_GRACE_SECONDS,
    mcp_ensure_default_session!, mcp_new_session_result, mcp_list_sessions_result,
    mcp_close_session_result, mcp_call_tool, MCP_DEFAULT_SESSION_NAME

include("errors.jl")
include("protocol/message.jl")
include("session/module_session.jl")
include("session/manager.jl")
include("middleware/core.jl")
include("middleware/eval.jl")
include("middleware/describe.jl")
include("middleware/load_file.jl")
include("middleware/complete.jl")
include("middleware/lookup.jl")
include("middleware/interrupt.jl")
include("middleware/stdin.jl")
include("middleware/session.jl")
include("middleware/session_ops.jl")
include("middleware/unknown_op.jl")
include("transport/tcp.jl")
include("server.jl")
include("mcp_adapter.jl")

"""Return the canonical protocol name for this package."""
protocol_name() = "REPLy"

"""Return a human-readable package version string."""
version_string() = string(pkgversion(REPLy))

end
