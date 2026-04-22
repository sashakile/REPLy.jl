module REPLy

using JSON3
using Sockets

export protocol_name, version_string
export AbstractTransport, JSONTransport, MessageTooLargeError, close, done_response,
    error_response, receive, response_message, send!, validate_request,
    DEFAULT_MAX_MESSAGE_BYTES
export build_handler, serve, server_port, server_socket_path
export RequestContext, HandlerContext, dispatch_middleware
export collect_reply_stream, mcp_eval_request, mcp_initialize_result, mcp_tools,
    reply_stream_to_mcp_result

include("errors.jl")
include("protocol/message.jl")
include("session/module_session.jl")
include("session/manager.jl")
include("middleware/core.jl")
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
