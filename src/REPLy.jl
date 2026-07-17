module REPLy

using Dates
using PrecompileTools: @setup_workload, @compile_workload
using JSON3
using REPL
using Sockets
using UUIDs

export protocol_name, version_string, replyc
export AbstractTransport, JSONTransport, MessageTooLargeError, close, done_response,
    error_response, receive, response_message, send!, validate_request,
    DEFAULT_MAX_MESSAGE_BYTES, DEFAULT_MAX_REPR_BYTES, OUTPUT_TRUNCATION_MARKER,
    truncate_output
export build_handler, serve, serve_multi, serve_mcp, AbstractServerHandle,
    MultiListenerServer, server_port, server_socket_path, ServerState
export EvalGate, acquire!, release!, active_count
export register_active_eval!, unregister_active_eval!, active_eval_tasks
export get_or_create_named_session!
export RequestContext, HandlerContext, dispatch_middleware, shutdown_middleware!, mutable_copy
export validate_session_name, MAX_SESSION_NAME_BYTES
export session_id, is_trusted
export SessionState, SessionIdle, SessionRunning, SessionClosed
export session_state, session_eval_task, session_last_active_at, session_eval_count, session_eval_id, session_module_name
export begin_eval!, end_eval!, try_begin_eval!, sweep_idle_sessions!
export MAX_SESSION_HISTORY_SIZE, clamp_history!, StdinFeeder, teardown_stdin_feeder!
export ResourceLimits
export effective_limit
export AuditLog, AuditLogEntry, audit_entries, record_audit!, AuditMiddleware
export MiddlewareDescriptor, descriptor, validate_stack
export EvalRequest, parse_eval_request
export LoadFileMiddleware, CompleteMiddleware, LookupMiddleware, LsBindingsMiddleware
export collect_reply_stream, mcp_eval_request, mcp_initialize_result, mcp_tools,
    reply_stream_to_mcp_result, DEFAULT_COLLECT_TIMEOUT_SECONDS, DEFAULT_CLOSE_GRACE_SECONDS,
    mcp_ensure_default_session!, mcp_new_session_result, mcp_list_sessions_result,
    mcp_close_session_result, mcp_call_tool, MCP_DEFAULT_SESSION_NAME

include("errors.jl")
include("protocol/message.jl")
include("session/module_session.jl")
include("config/resource_limits.jl")
include("config/eval_gate.jl")
include("config/server_state.jl")
include("security/audit.jl")
include("session/manager.jl")
include("io_capture.jl")
include("middleware/core.jl")
include("middleware/audit.jl")
include("middleware/eval_request.jl")
include("middleware/eval.jl")
include("middleware/describe.jl")
include("middleware/load_file.jl")
include("middleware/reload_file.jl")
include("middleware/complete.jl")
include("middleware/lookup.jl")
include("middleware/ls_bindings.jl")
include("middleware/interrupt.jl")
include("middleware/ping.jl")
include("middleware/stdin.jl")
include("middleware/session.jl")
include("middleware/session_ops.jl")
include("middleware/unknown_op.jl")
include("transport/tcp.jl")
include("server.jl")
include("mcp/tools.jl")
include("mcp/requests.jl")
include("mcp/results.jl")
include("mcp/server.jl")
include("replyc.jl")

"""Return the canonical protocol name for this package."""
protocol_name() = "REPLy"

"""Return a human-readable package version string."""
version_string() = string(pkgversion(REPLy))

# Precompile the first-request hot path so first-use latency (TTFX) is paid at
# package build time instead of on the first client request.
#
# The eval op materialises an anonymous session module via `Core.eval`, which
# Julia forbids during precompilation. We therefore drive the middleware stack
# with request shapes that exercise dispatch, validation, and response
# formatting without executing user code, then cover the eval path with
# `precompile` directives (inference only, no evaluation).
@setup_workload begin
    @compile_workload begin
        handler = build_handler()
        # Non-eval ops traverse the middleware dispatch chain without
        # materialising a session module (which `Core.eval` would forbid during
        # precompilation). The unknown op falls through every middleware layer,
        # precompiling the full recursive tuple-dispatch tail.
        handler(Dict("op" => "describe", "id" => "pc-describe"))
        handler(Dict("op" => "ping", "id" => "pc-ping"))
        handler(Dict("op" => "frobnicate", "id" => "pc-unknown"))
        for msg in (
            Dict("op" => "describe", "id" => "pc-v"),
            Dict{String, String}(),
        )
            validate_request(msg)
        end
    end
    # The eval execution path cannot run during precompilation (it evals user
    # code into a fresh anonymous module), so cover it with inference-only
    # `precompile` directives instead.
    precompile(_run_eval_core, (Module, String, String, Int))
    precompile(eval_responses, (RequestContext, Dict{String, String}))
    precompile(lookup_responses, (RequestContext, Dict{String, String}))
    precompile(buffered_output_messages, (String, String, String))
end

end
